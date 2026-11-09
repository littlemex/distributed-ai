"""Create, describe or delete the campaign's EFA-enabled FSx for Lustre file system.

Event: {"action": "create" | "describe" | "delete"}
- create is idempotent: an existing file system with the campaign tag (not being deleted) is returned.
- describe returns {"state", "id", "dns", "mountName"} or {"state": "ABSENT"}.
- delete deletes every file system with the campaign tag, without a final backup.
"""
import os

import boto3

fsx = boto3.client("fsx")
TAG_KEY, TAG_VALUE = os.environ["TAG_KEY"], os.environ["TAG_VALUE"]


def _ours():
    found = []
    for page in fsx.get_paginator("describe_file_systems").paginate():
        for f in page["FileSystems"]:
            tags = {t["Key"]: t["Value"] for t in f.get("Tags", [])}
            if tags.get(TAG_KEY) == TAG_VALUE and f["Lifecycle"] not in ("DELETING", "FAILED"):
                found.append(f)
    return found


def _view(f):
    return {"state": f["Lifecycle"], "id": f["FileSystemId"], "dns": f.get("DNSName"),
            "mountName": f.get("LustreConfiguration", {}).get("MountName")}


def handler(event, _ctx):
    action = (event or {}).get("action", "describe")
    ours = _ours()
    if action == "describe":
        return _view(ours[0]) if ours else {"state": "ABSENT"}
    if action == "delete":
        for f in ours:
            fsx.delete_file_system(FileSystemId=f["FileSystemId"], LustreConfiguration={"SkipFinalBackup": True})
        return {"deleted": [f["FileSystemId"] for f in ours]}
    if action == "create":
        if ours:
            return _view(ours[0])
        r = fsx.create_file_system(
            FileSystemType="LUSTRE",
            FileSystemTypeVersion=os.environ["LUSTRE_VERSION"],
            StorageCapacity=int(os.environ["STORAGE_GIB"]),
            StorageType="SSD",
            SubnetIds=[os.environ["SUBNET_ID"]],
            SecurityGroupIds=[os.environ["SG_ID"]],
            Tags=[{"Key": TAG_KEY, "Value": TAG_VALUE}, {"Key": "Name", "Value": f"{TAG_VALUE}-lustre"}],
            LustreConfiguration={
                "DeploymentType": "PERSISTENT_2",
                "PerUnitStorageThroughput": int(os.environ["THROUGHPUT_PER_TIB"]),
                "EfaEnabled": True,
                "MetadataConfiguration": {"Mode": "AUTOMATIC"},
                "DataCompressionType": "NONE",
            },
        )
        return _view(r["FileSystem"])
    raise ValueError(f"unknown action {action}")
