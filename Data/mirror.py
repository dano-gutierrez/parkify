"""Publish the validated GitHub release to Bucketlist using scoped, short-lived uploads."""
import hashlib
import json
import os
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request

PROJECT = "https://bqmjackxfpwxptkqjseg.supabase.co"
BUCKET = "parkify-curbs"
REPO = "dano-gutierrez/parkify"
PUBLISHER = PROJECT + "/functions/v1/parkify-publish"


def request(url, *, data=None, headers=None, method=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=100) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        # Signed upload URLs are credentials. Keep them out of the workflow logs.
        message = error.read(1024).decode(errors="replace")
        raise RuntimeError(f"HTTP {error.code} on {urllib.parse.urlsplit(url).hostname}: {message}") from None


def identity():
    url = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"] + "&audience=parkify-curbs"
    headers = {"Authorization": "Bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]}
    return json.loads(request(url, headers=headers))["value"]


def authorize(tag, parts, cleanup=False):
    return json.loads(request(PUBLISHER, data=json.dumps({"tag":tag,"names":parts,"cleanup":cleanup}).encode(),
                              headers={"Authorization":"Bearer "+identity(),"Content-Type":"application/json"}))


def publish():
    tag = os.environ.get("RELEASE_TAG") or subprocess.check_output(
        ["gh","api",f"repos/{REPO}/releases/latest","--jq",".tag_name"], text=True).strip()
    if not re.fullmatch(r"city-\d{1,16}-\d{1,4}",tag):
        raise ValueError("Unrecognized release tag")
    origin = f"https://github.com/{REPO}/releases/download/{tag}/"
    manifest = json.loads(request(origin+"manifest.json"))
    names = [part["name"] for part in manifest["parts"]]
    if manifest["schema"]!=1 or not names or any(not re.fullmatch(r"[a-f0-9]{64}\.gzpart",n) for n in names):
        raise ValueError("Invalid city manifest")
    urls = authorize(tag,names)["urls"]
    for part in manifest["parts"]:
        name=part["name"]
        data=request(origin+name)
        if len(data)!=part["bytes"] or hashlib.sha256(data).hexdigest()+".gzpart"!=name:
            raise ValueError("Source release checksum mismatch")
        request(urls[tag+"/"+name],method="PUT",data=data,
                headers={"Content-Type":"application/octet-stream","Cache-Control":"max-age=31536000"})
    base=PROJECT+"/storage/v1/object/public/"+BUCKET+"/"
    manifest["base"]=base+tag+"/"
    request(urls["manifest.json"],method="PUT",data=json.dumps(manifest).encode(),
            headers={"Content-Type":"application/json","Cache-Control":"max-age=0"})
    authorize(tag,[],cleanup=True)
    print("Published",manifest["zones"],"curbs to",base+"manifest.json")


if __name__=="__main__":
    publish()
