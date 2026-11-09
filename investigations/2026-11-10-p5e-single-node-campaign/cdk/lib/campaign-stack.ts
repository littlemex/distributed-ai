import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as scheduler from 'aws-cdk-lib/aws-scheduler';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';
import * as fs from 'fs';
import * as path from 'path';

export interface CampaignStackProps extends cdk.StackProps {
  availabilityZone: string;      // the Capacity Block's AZ; the subnet and FSx for Lustre live here
  amiId: string;                 // pinned so every attempt boots the same image
  instanceType: string;
  efaInterfaces: number;         // one EFA interface per network card (p5e.48xlarge has 32)
  capacityReservationId: string; // Capacity Block reservation id ('' = no scheduled launch)
  launchAtUtc: string[];         // one-time launch attempts, e.g. 2026-11-10T11:31:00
  cleanupAtUtc: string;          // when the FSx file system is deleted at the latest
  rootVolumeGb: number;
}

/**
 * One GPU instance in a Capacity Block, launched on a schedule, with:
 * - a private subnet behind a NAT gateway (an instance with several network cards gets no public IP),
 * - a security group that allows all traffic to and from itself (EFA and FSx for Lustre over EFA need both directions),
 * - a retained results bucket the instance syncs to, so results outlive the instance,
 * - a Lambda that creates and deletes the EFA-enabled FSx for Lustre file system, so the file system
 *   only bills while the instance can use it. The instance can call it early; a schedule calls it at the end.
 */
export class CampaignStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: CampaignStackProps) {
    super(scope, id, props);
    if (!props.amiId || !props.availabilityZone) throw new Error('amiId and availabilityZone are required context values');

    const vpc = new ec2.Vpc(this, 'Vpc', {
      ipAddresses: ec2.IpAddresses.cidr('10.40.0.0/16'),
      availabilityZones: [props.availabilityZone],
      natGateways: 1,
      subnetConfiguration: [
        { name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
        { name: 'private', subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS, cidrMask: 20 },
      ],
      gatewayEndpoints: { s3: { service: ec2.GatewayVpcEndpointAwsService.S3 } },
    });
    const subnet = vpc.privateSubnets[0];

    const sg = new ec2.SecurityGroup(this, 'Sg', {
      vpc, allowAllOutbound: true, description: `${id}: no inbound except from itself`,
    });
    sg.addIngressRule(sg, ec2.Port.allTraffic(), 'self (EFA, FSx for Lustre)');
    // EFA needs an explicit outbound rule to the group itself; 0.0.0.0/0 is not enough.
    sg.addEgressRule(sg, ec2.Port.allTraffic(), 'self (EFA)');

    const bucket = new s3.Bucket(this, 'Results', {
      bucketName: `${id.toLowerCase()}-${this.account}-${this.region}`,
      versioned: true,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // --- FSx for Lustre control (create / delete / describe) -------------------------------
    const fsxTag = { key: 'Campaign', value: id };
    const fsxFn = new lambda.Function(this, 'FsxControl', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'index.handler',
      timeout: cdk.Duration.minutes(2),
      code: lambda.Code.fromAsset(path.join(__dirname, '..', 'lambda', 'fsx_control')),
      environment: {
        TAG_KEY: fsxTag.key, TAG_VALUE: fsxTag.value,
        SUBNET_ID: subnet.subnetId, SG_ID: sg.securityGroupId,
        STORAGE_GIB: '4800', THROUGHPUT_PER_TIB: '1000', LUSTRE_VERSION: '2.15',
      },
    });
    fsxFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['fsx:CreateFileSystem', 'fsx:DescribeFileSystems', 'fsx:DeleteFileSystem', 'fsx:TagResource', 'fsx:ListTagsForResource'],
      resources: ['*'],
    }));
    // FSx creates its ENIs with the caller's permissions.
    fsxFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['ec2:CreateNetworkInterface', 'ec2:CreateNetworkInterfacePermission', 'ec2:DeleteNetworkInterface',
        'ec2:DescribeNetworkInterfaces', 'ec2:DescribeSubnets', 'ec2:DescribeSecurityGroups', 'ec2:DescribeVpcs',
        'ec2:CreateTags'],
      resources: ['*'],
    }));
    fsxFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ['iam:CreateServiceLinkedRole', 'iam:AttachRolePolicy', 'iam:PutRolePolicy'],
      resources: [`arn:aws:iam::${this.account}:role/aws-service-role/*fsx*`],
    }));

    // --- Instance ---------------------------------------------------------------------------
    const role = new iam.Role(this, 'InstanceRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore')],
    });
    bucket.grantReadWrite(role);
    fsxFn.grantInvoke(role);
    role.addToPolicy(new iam.PolicyStatement({ actions: ['fsx:DescribeFileSystems'], resources: ['*'] }));
    const profile = new iam.CfnInstanceProfile(this, 'InstanceProfile', { roles: [role.roleName] });

    // Everything the host needs to find, in one place; the bootstrap reads it at boot.
    const cfgParam = new ssm.StringParameter(this, 'Config', {
      parameterName: `/${id}/config`,
      stringValue: cdk.Stack.of(this).toJsonString({
        bucket: bucket.bucketName, region: this.region, fsxFunction: fsxFn.functionName,
        subnetId: subnet.subnetId, securityGroupId: sg.securityGroupId,
      }),
    });
    cfgParam.grantRead(role);

    const bootstrap = fs.readFileSync(path.join(__dirname, '..', '..', 'host', 'bootstrap.sh'), 'utf-8')
      .replace(/__CONFIG_PARAM__/g, `/${id}/config`).replace(/__REGION__/g, this.region);

    // Network card 0 carries the primary interface (EFA with IP); the other cards carry EFA-only interfaces.
    const networkInterfaces = Array.from({ length: props.efaInterfaces }, (_, i) => ({
      networkCardIndex: i,
      deviceIndex: i === 0 ? 0 : 1,
      interfaceType: i === 0 ? 'efa' : 'efa-only',
      subnetId: subnet.subnetId,
      groups: [sg.securityGroupId],
      deleteOnTermination: true,
    }));

    const lt = new ec2.CfnLaunchTemplate(this, 'LaunchTemplate', {
      launchTemplateName: `${id}-lt`,
      launchTemplateData: {
        imageId: props.amiId,
        instanceType: props.instanceType,
        iamInstanceProfile: { arn: profile.attrArn },
        networkInterfaces,
        metadataOptions: { httpTokens: 'required', httpPutResponseHopLimit: 2 },
        instanceInitiatedShutdownBehavior: 'terminate',
        blockDeviceMappings: [{
          deviceName: '/dev/sda1',
          ebs: { volumeSize: props.rootVolumeGb, volumeType: 'gp3', iops: 16000, throughput: 1000, encrypted: true, deleteOnTermination: true },
        }],
        userData: cdk.Fn.base64(bootstrap),
        tagSpecifications: [{ resourceType: 'instance', tags: [{ key: 'Name', value: `${id}-runner` }, { key: 'Campaign', value: id }] }],
      },
    });
    lt.node.addDependency(profile);

    // --- Schedules ----------------------------------------------------------------------------
    const schedRole = new iam.Role(this, 'SchedulerRole', { assumedBy: new iam.ServicePrincipal('scheduler.amazonaws.com') });
    fsxFn.grantInvoke(schedRole);
    // RunInstances when the Capacity Block opens. A second success is impossible (the block holds the
    // instance count we bought), so several attempts are safe and cover a slow block activation.
    if (props.capacityReservationId && props.launchAtUtc.length) {
      schedRole.addToPolicy(new iam.PolicyStatement({ actions: ['ec2:RunInstances', 'ec2:CreateTags'], resources: ['*'] }));
      schedRole.addToPolicy(new iam.PolicyStatement({ actions: ['iam:PassRole'], resources: [role.roleArn] }));
      const input = {
        LaunchTemplate: { LaunchTemplateId: lt.ref, Version: '$Latest' },
        MinCount: 1, MaxCount: 1,
        InstanceMarketOptions: { MarketType: 'capacity-block' },
        CapacityReservationSpecification: { CapacityReservationTarget: { CapacityReservationId: props.capacityReservationId } },
      };
      props.launchAtUtc.forEach((at, i) => new scheduler.CfnSchedule(this, `Launch${i}`, {
        name: `${id}-launch-${i}`,
        scheduleExpression: `at(${at})`,
        scheduleExpressionTimezone: 'UTC',
        flexibleTimeWindow: { mode: 'OFF' },
        target: {
          arn: 'arn:aws:scheduler:::aws-sdk:ec2:runInstances',
          roleArn: schedRole.roleArn,
          input: cdk.Stack.of(this).toJsonString(input),
          retryPolicy: { maximumRetryAttempts: 0 },
        },
      }));
    }
    // Delete the file system after the block ends even if nobody is watching.
    if (props.cleanupAtUtc) {
      new scheduler.CfnSchedule(this, 'FsxCleanup', {
        name: `${id}-fsx-cleanup`,
        scheduleExpression: `at(${props.cleanupAtUtc})`,
        scheduleExpressionTimezone: 'UTC',
        flexibleTimeWindow: { mode: 'OFF' },
        target: { arn: fsxFn.functionArn, roleArn: schedRole.roleArn, input: JSON.stringify({ action: 'delete' }) },
      });
    }

    new cdk.CfnOutput(this, 'BucketName', { value: bucket.bucketName });
    new cdk.CfnOutput(this, 'LaunchTemplateId', { value: lt.ref });
    new cdk.CfnOutput(this, 'FsxFunction', { value: fsxFn.functionName });
    new cdk.CfnOutput(this, 'SubnetId', { value: subnet.subnetId });
  }
}
