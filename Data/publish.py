"""Publish validated immutable parts first and the manifest last."""
import json
import os
import pathlib
import subprocess
import sys
import urllib.request

folder=pathlib.Path(sys.argv[1])
manifest=json.loads((folder/"manifest.json").read_text())
tag="city-"+os.environ["GITHUB_RUN_ID"]+"-"+os.environ["GITHUB_RUN_ATTEMPT"]
repo=os.environ["GITHUB_REPOSITORY"]
files=[folder/p["name"] for p in manifest["parts"]]
manifest["sourceCommit"]=os.environ["GITHUB_SHA"]
manifest["base"]=f"https://github.com/{repo}/releases/download/{tag}/"
(folder/"manifest.json").write_text(json.dumps(manifest))
subprocess.run(["gh","release","create",tag,"--draft","--target",os.environ["GITHUB_REF_NAME"],"--title","San Francisco curb data · "+manifest["generated"],"--notes",f"{manifest['zones']:,} mapped curb segments. Source dates and rules are in the offline database.",str(folder/"manifest.json"),*map(str,files)], check=True)
subprocess.run(["gh","release","edit",tag,"--draft=false","--latest"],check=True)
