import { createRemoteJWKSet, jwtVerify } from "npm:jose@6.2.18";
import { createClient } from "npm:@supabase/supabase-js@2.119.2";

const issuer = "https://token.actions.githubusercontent.com";
const keys = createRemoteJWKSet(new URL(issuer + "/.well-known/jwks"));
const bucket = "parkify-curbs";
const repo = "dano-gutierrez/parkify";
const tagPattern = /^city-\d{1,16}-\d{1,4}$/;
const partPattern = /^[a-f0-9]{64}\.gzpart$/;
const json = (value: unknown, status = 200) => Response.json(value, { status, headers: { "Cache-Control": "no-store" } });

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({error:"POST required"},405);
  const token = request.headers.get("authorization")?.replace(/^Bearer /, "") ?? "";
  try {
    const { payload } = await jwtVerify(token, keys, {
      issuer, audience:"parkify-curbs", algorithms:["RS256"], requiredClaims:["exp","iat","repository_id","workflow_ref","ref"],
    });
    if (payload.repository_id !== "1471345131" || payload.ref !== "refs/heads/main" ||
        payload.workflow_ref !== repo + "/.github/workflows/city.yml@refs/heads/main" ||
        !["schedule","workflow_dispatch"].includes(String(payload.event_name))) {
      return json({error:"Parkify main publisher required"},403);
    }
  } catch { return json({error:"Invalid publisher identity"},401); }

  try {
    const { tag, names, cleanup } = await request.json();
    if (!tagPattern.test(tag) || !Array.isArray(names) || names.length > 50 ||
        names.some((n: unknown) => typeof n !== "string" || !partPattern.test(n))) {
      return json({error:"Invalid release"},400);
    }
    const client = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      {auth:{persistSession:false,autoRefreshToken:false}});
    const storage = client.storage.from(bucket);
    if (cleanup === true) {
      // This bucket is reserved for Parkify. Retain three snapshots for downloads in flight.
      const {data:folders,error} = await storage.list("",{limit:1000});
      if (error) throw error;
      const versions=(folders ?? []).filter(v=>!v.id && tagPattern.test(v.name))
        .map(v=>v.name).sort((a,b)=>Number(b.split("-")[1])-Number(a.split("-")[1]));
      for (const old of versions.slice(3).filter(v=>v!==tag)) {
        const {data, error:ls} = await storage.list(old,{limit:100});
        if (ls) throw ls;
        const paths=(data ?? []).filter(v=>partPattern.test(v.name)).map(v=>old+"/"+v.name);
        if (paths.length) { const {error:del}=await storage.remove(paths); if(del) throw del; }
      }
      return json({ok:true});
    }
    const {data:existing,error:lookup}=await client.storage.getBucket(bucket);
    if (lookup || !existing) {
      const {error}=await client.storage.createBucket(bucket,{public:true,fileSizeLimit:24*1024*1024,
        allowedMimeTypes:["application/octet-stream","application/json"]});
      if (error) throw error;
    } else if (!existing.public) { return json({error:"Bucket is private"},409); }
    const urls: Record<string,string>={};
    for (const path of [...names.map((n:string)=>tag+"/"+n),"manifest.json"]) {
      const {data,error}=await storage.createSignedUploadUrl(path,{upsert:true});
      if (error || !data) throw error ?? Error("No upload URL");
      urls[path]=data.signedUrl;
    }
    return json({urls});
  } catch (error) {
    return json({error:error instanceof Error ? error.message : "Storage request failed"},502);
  }
});
