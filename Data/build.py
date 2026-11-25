"""Build a read-only spatial database from the published San Francisco curb inventory."""
import argparse
import csv
import datetime as dt
import gzip
import hashlib
import io
import json
import math
import os
import re
import sqlite3
import time
import urllib.parse
import urllib.request
import zlib
from pathlib import Path
from zoneinfo import ZoneInfo

CITY = "https://data.sf.gov/resource/"
HOLIDAYS = "https://www.sfmta.com/getting-around/drive-park/holiday-enforcement-schedule"
SF = ZoneInfo("America/Los_Angeles")
TODAY = dt.datetime.now(SF).date()
DAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]


def fetch(url):
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Parkify public curb importer", "Accept-Encoding": "gzip"})
            with urllib.request.urlopen(req, timeout=180) as res:
                body = res.read()
                return gzip.decompress(body) if res.headers.get("Content-Encoding") == "gzip" else body
        except (OSError, EOFError):
            if attempt == 4:
                raise
            time.sleep(2 ** attempt)


def rows(dataset, columns, where=None, key=":id"):
    # Seek by a stable unique upstream key. Fail if the source changes during the import.
    def query(**params):
        return json.loads(fetch(CITY + dataset + ".json?" + urllib.parse.urlencode(params)))
    base = {"$where": where} if where else {}
    expected = int(query(**{"$select": "count(*) as n"}, **base)[0]["n"])
    seen = 0
    last = None
    while seen < expected:
        conditions = [where] if where else []
        if last is not None:
            literal = str(int(last)) if key == "objectid" else "'" + str(last).replace("'", "''") + "'"
            conditions.append(f"{key} > {literal}")
        params = {"$select": columns + "," + key + " as paging_key", "$limit": 10000, "$order": key}
        if conditions:
            params["$where"] = " AND ".join("(" + item + ")" for item in conditions)
        page = query(**params)
        if not page:
            break
        last = page[-1]["paging_key"]
        yield from page
        seen += len(page)
    if seen != expected:
        raise ValueError(f"{dataset}: received {seen:,} of {expected:,} records")
    print(dataset, seen, flush=True)


def pack(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def minute(value):
    h, m = map(int, value.split(":")[:2])
    if not (0 <= h <= 24 and 0 <= m < 60 and (h < 24 or m == 0)):
        raise ValueError(value)
    return h * 60 + m


def numbers(value, low, high):
    result = [int(x) for x in (value or "").split(",") if x.strip()]
    if any(not low <= x <= high for x in result):
        raise ValueError(value)
    return result


def digital(row):
    cat = row["policy_category"]
    label = row.get("label") or cat
    rule = {"reason": cat, "kind": "ban"}
    if "cleaning" in label.lower() or "sweep" in label.lower():
        rule.update(kind="sweep", reason="Street cleaning")
    elif cat in ("General Parking", "Residential Permit Parking"):
        rule.update(kind="paid" if row.get("paid_parking_flag") else "park", reason="Meter payment" if row.get("paid_parking_flag") else "Posted time limit")
        match = re.search(r"(?:Residential Permit|RPP)\s+([A-Z]{1,2})\b", label)
        if match:
            rule["permit"] = match.group(1)
        elif cat == "Residential Permit Parking":
            rule["reason"] = "Residential time limit"
    elif cat == "Driveway":
        rule["reason"] = "Driveway"
    try:
        rule.update(days=[DAYS.index(v) for v in row["days_of_week"].split(",")],
                    start=minute(row["time_of_day_start"]), end=minute(row["time_of_day_end"]))
        if rule["end"] == 1439:
            rule["end"] = 1440
        for src, dest, low, high in [("weeks_of_month","weeks",1,5), ("months","months",1,12), ("days_of_month","dates",1,31)]:
            if row.get(src):
                rule[dest] = numbers(row[src], low, high)
        for name, target in [("start_date", "first"), ("end_date", "last")]:
            if row.get(name):
                rule[target] = row[name][:10]
        for key, dest in [("max_stay","limit"), ("no_return","noReturn")]:
            if float(row.get(key, 0)) > 0:
                factor = {"minute":1,"hour":60,"day":1440}[row[key+"_unit"].lower().rstrip("s")]
                rule[dest] = int(float(row[key]) * factor)
        if any(row.get(k,"NONE").upper() not in ("NONE","") for k in ("designated_period","designated_period_except")):
            raise ValueError("conditional period")
        if rule["kind"] in ("park","paid") and row.get("vehicle_type","NONE").upper() not in ("NONE","ALL","PERSONAL","PASSENGER CAR"):
            raise ValueError("vehicle-specific parking")
    except (ValueError, KeyError):
        return {"kind":"unknown","reason":label}
    return rule


SCHEMA = """
create table zone(id integer primary key, uuid text unique, block text, cnn text, street text,
    cross1 text, cross2 text, side text, line text);
create virtual table bounds using rtree(id,minX,maxX,minY,maxY);
create table policy(id integer primary key, json text unique);
create table applies(zone integer, policy integer, primary key(zone,policy)) without rowid;
create index zone_cnn on zone(cnn, side);
create table holiday(day text primary key, exceptions text);
create table meta(name text primary key, value text);
"""
SIDES = {"north":"N","south":"S","east":"E","west":"W","northeast":"NE","northwest":"NW","southeast":"SE","southwest":"SW"}


class Builder:
    def __init__(self, db):
        self.db = db
        self.policies = {}
        self.zones = {}
        self.latest = ""

    def apply(self, zone, rule):
        key = pack(rule)
        if key not in self.policies:
            self.policies[key] = self.db.execute("insert into policy(json) values(?)",(key,)).lastrowid
        self.db.execute("insert or ignore into applies values(?,?)",(zone,self.policies[key]))

    def curbs(self):
        fields = "curb_zone_id,blockface_id,street_cnn,street_name,cross_street_start_name,cross_street_end_name,side_of_street,shape,policy_category,label,paid_parking_flag,days_of_week,time_of_day_start,time_of_day_end,weeks_of_month,months,days_of_month,start_date,end_date,max_stay,max_stay_unit,no_return,no_return_unit,vehicle_type,designated_period,designated_period_except,data_as_of"
        for r in rows("wntw-x37e", fields, key="objectid"):
            uuid = r["curb_zone_id"]
            if uuid not in self.zones:
                shape = r.get("shape") or {}
                if shape.get("type") != "LineString" or len(shape["coordinates"]) < 2:
                    continue
                line = [[round(x,6),round(y,6)] for x,y,*_ in shape["coordinates"]]
                xs,ys = zip(*line)
                key = self.db.execute("insert into zone(uuid,block,cnn,street,cross1,cross2,side,line) values(?,?,?,?,?,?,?,?)",
                    (uuid,r.get("blockface_id",""),r.get("street_cnn",""),r.get("street_name",""),r.get("cross_street_start_name",""),r.get("cross_street_end_name",""),r.get("side_of_street",""),pack(line))).lastrowid
                self.db.execute("insert into bounds values(?,?,?,?,?)",(key,min(xs),max(xs),min(ys),max(ys)))
                self.zones[uuid] = key
            self.apply(self.zones[uuid], digital(r))
            self.latest = max(self.latest,r.get("data_as_of","")[:10])
        if len(self.zones) < 250000 or not self.latest:
            raise ValueError("Incomplete Digital Curb inventory")
        self.db.execute("insert into meta values('curbAsOf',?)",(self.latest,))

    def sweeping(self):
        for r in rows("yhqp-riqs","cnn,blockside,weekday,fromhour,tohour,week1,week2,week3,week4,week5,holidays"):
            side = SIDES.get(r.get("blockside","").lower())
            if not side:
                continue
            day = r.get("weekday","").lower()[:3]
            if day not in DAYS:
                continue
            rule = dict(kind="sweep",reason="Street cleaning",days=[DAYS.index(day)],
                        weeks=[i for i in range(1,6) if r.get(f"week{i}")=="1"],
                        start=int(r["fromhour"])*60,end=int(r["tohour"])*60)
            if not rule["weeks"]:
                continue
            for zone, in self.db.execute("select id from zone where cnn=? and side=?",(r.get("cnn"),side)):
                self.apply(zone,rule)

    def tow(self):
        fields = "cnn,sideofstreet,startdate,enddate,starttime,endtime,_24hourenforcement,status,latitude,longitude,streetfrontagefeet"
        condition = f"enddate >= '{TODAY}' and startdate < '{TODAY+dt.timedelta(days=90)}'"
        for r in rows("6r5h-j298", fields,condition):
            if re.search(r"cancel|denied|revoked|expired",r.get("status",""),re.I):
                continue
            side = SIDES.get(r.get("sideofstreet","").lower(),r.get("sideofstreet","").upper())
            rule = dict(kind="unknown",reason="Temporary tow posting on this block",first=r["startdate"][:10],last=r["enddate"][:10])
            try:
                if r.get("_24hourenforcement","").lower()=="yes":
                    rule.update(start=0,end=1440)
                else:
                    for key, field in [("start","starttime"),("end","endtime")]:
                        d = dt.datetime.strptime(r[field].strip(),"%I:%M %p")
                        rule[key] = d.hour*60+d.minute
            except (ValueError,KeyError):
                pass
            for zone,curbside,line in self.db.execute("select id,side,line from zone where cnn=?",(r.get("cnn"),)):
                if side in SIDES.values() and curbside != side:
                    continue
                precise = False
                if (side == curbside or side == "BOTH") and r.get("longitude") and r.get("latitude"):
                    points=json.loads(line)
                    # A point with unspecified frontage direction supports only a very close match.
                    precise = line_distance(float(r["longitude"]),float(r["latitude"]),points)<3
                candidate = dict(rule)
                if precise and "end" in rule and "start" in rule:
                    candidate.update(kind="ban",reason="Temporary tow-away zone")
                self.apply(zone,candidate)

    def meters(self):
        meters = {}
        for r in rows("8vzz-qzz9","post_id,longitude,latitude,street_seg_ctrln_id,on_offstreet_type", "on_offstreet_type='ON'",key="objectid"):
            if not r.get("latitude") or not r.get("longitude"):
                continue
            x,y=float(r["longitude"]),float(r["latitude"])
            choices=[]
            for zone,line in self.db.execute("select z.id,line from zone z join bounds b on z.id=b.id where cnn=? and minX<? and maxX>? and minY<? and maxY>?",(r.get("street_seg_ctrln_id"),x+.00012,x-.00012,y+.00010,y-.00010)):
                choices.append((line_distance(x,y,json.loads(line)),zone))
            choices.sort()
            if choices and choices[0][0]<=8 and (len(choices)==1 or choices[1][0]-choices[0][0]>2):
                meters[r["post_id"]]=choices[0][1]
        condition=f"enddate >= '{TODAY}' and startdate < '{TODAY+dt.timedelta(days=90)}' and scheduletype in ('OP','TOW','ALT')"
        for r in rows("qq7v-hds4","postid,scheduletype,startdate,enddate,dayofweek,starttime,endtime,timelimitminutes",condition):
            zone=meters.get(r["postid"])
            if zone is None:
                continue
            day=r.get("dayofweek","").lower()[:2]
            try:
                rule=dict(kind={"OP":"paid","TOW":"ban","ALT":"unknown"}[r["scheduletype"]],
                          reason={"OP":"Meter payment","TOW":"Meter tow-away hours","ALT":"Alternate meter schedule"}[r["scheduletype"]],
                          first=r["startdate"][:10],last=r["enddate"][:10],days=[[d[:2] for d in DAYS].index(day)],
                          start=minute(r["starttime"]),end=minute(r["endtime"]))
                limit=int(float(r.get("timelimitminutes",0)))
                if limit>0:
                    rule["limit"]=limit
            except (ValueError, KeyError):
                rule=dict(kind="unknown",reason="Check meter schedule")
            self.apply(zone,rule)


def line_distance(x,y,points):
    distances=[]
    for a,b in zip(points,points[1:]):
        ax,ay=(a[0]-x)*88000,(a[1]-y)*111000
        dx,dy=(b[0]-a[0])*88000,(b[1]-a[1])*111000
        t=max(0,min(1,-(ax*dx+ay*dy)/(dx*dx+dy*dy or 1)))
        distances.append(math.hypot(ax+t*dx,ay+t*dy))
    return min(distances)


def build(out):
    from holidays_sf import exceptions
    out.mkdir(exist_ok=True,parents=True)
    path=out/"city.sqlite"
    db=sqlite3.connect(path)
    db.executescript("pragma journal_mode=off; pragma synchronous=off;" + SCHEMA)
    b=Builder(db)
    b.curbs()
    b.sweeping()
    b.tow()
    b.meters()
    for day, exc in exceptions(fetch(HOLIDAYS).decode()).items():
        db.execute("insert into holiday values(?,?)",(day,pack(sorted(exc))))
    db.execute("insert into meta values('generated',?)",(str(TODAY),))
    db.commit()
    if db.execute("pragma integrity_check").fetchone()!=("ok",) or db.execute("select count(*) from bounds").fetchone()[0]!=len(b.zones):
        raise ValueError("Spatial snapshot failed validation")
    db.close()
    # Record both compressed and expanded sizes; write immutable parts below Storage's free-plan object limit.
    compressor=zlib.compressobj(9,wbits=31)
    parts=[]
    buffer=bytearray()
    digest=hashlib.sha256()
    def flush(size):
        part=bytes(buffer[:size])
        del buffer[:size]
        name=hashlib.sha256(part).hexdigest()+".gzpart"
        (out/name).write_bytes(part)
        parts.append({"name":name,"bytes":len(part)})
    with path.open("rb") as source:
        while chunk:=source.read(1<<20):
            digest.update(chunk)
            buffer.extend(compressor.compress(chunk))
            if len(buffer)>=20<<20:
                flush(20<<20)
    buffer.extend(compressor.flush())
    if buffer:
        flush(len(buffer))
    (out/"manifest.json").write_text(pack(dict(schema=1,generated=str(TODAY),sha256=digest.hexdigest(),bytes=path.stat().st_size,zones=len(b.zones),parts=parts)))
    print("Validated", len(b.zones), "curbs;",len(parts),"parts",flush=True)


if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("output",type=Path)
    build(p.parse_args().output)
