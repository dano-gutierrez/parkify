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
base=os.getenv("SUPABASE_URL","").rstrip("/")
secret=os.getenv("SUPABASE_STORAGE_KEY","")
if bool(base)!=bool(secret):
    raise SystemExit("Set both Supabase Storage settings or neither.")
files=[folder/p["name"] for p in manifest["parts"]]
manifest["base"]=f"https://github.com/{repo}/releases/download/{tag}/"
if base:
    def upload(name,content,mime):
        req=urllib.request.Request(f"{base}/storage/v1/object/curbs/{name}",data=content,method="POST",
            headers={"apikey":secret,"Authorization":"Bearer "+secret,"Content-Type":mime,"x-upsert":"true"})
        with urllib.request.urlopen(req,timeout=180) as res:
            if not 200<=res.status<300:
                raise OSError(res.status)
    for path in files:
        upload(path.name,path.read_bytes(),"application/octet-stream")
    manifest["base"]=f"{base}/storage/v1/object/public/curbs/"
    upload("manifest.json",json.dumps(manifest).encode(),"application/json")
(folder/"manifest.json").write_text(json.dumps(manifest))
subprocess.run(["gh","release","create",tag,"--draft","--target",os.environ["GITHUB_SHA"],"--title","San Francisco curb data · "+manifest["generated"],"--notes",f"{manifest['zones']:,} mapped curb segments. Source dates and rules are in the offline database.",str(folder/"manifest.json"),*map(str,files)], check=True)
subprocess.run(["gh","release","edit",tag,"--draft=false","--latest"],check=True)
