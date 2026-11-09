#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { CampaignStack } from '../lib/campaign-stack';

const app = new cdk.App();
const ctx = (k: string, d = ''): string => app.node.tryGetContext(k) ?? d;

new CampaignStack(app, ctx('stackName', 'P5eCampaign'), {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION },
  availabilityZone: ctx('availabilityZone'),
  amiId: ctx('amiId'),
  instanceType: ctx('instanceType', 'p5e.48xlarge'),
  efaInterfaces: parseInt(ctx('efaInterfaces', '32'), 10),
  capacityReservationId: ctx('capacityReservationId'),
  launchAtUtc: ctx('launchAtUtc').split(',').filter(Boolean),
  cleanupAtUtc: ctx('cleanupAtUtc'),
  rootVolumeGb: parseInt(ctx('rootVolumeGb', '1000'), 10),
});
