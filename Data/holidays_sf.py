"""Extract only explicit, dated SFMTA enforcement exceptions."""
import datetime as dt
import re
from html.parser import HTMLParser


class Blocks(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tag = None
        self.blocks = []

    def handle_starttag(self, tag, attrs):
        if tag in ("h2", "h3", "p", "li"):
            self.tag = tag
            self.words = []

    def handle_data(self, data):
        if self.tag:
            self.words.append(data)

    def handle_endtag(self, tag):
        if tag == self.tag:
            self.blocks.append((tag," ".join(" ".join(self.words).split()).lower()))
            self.tag = None


def exceptions(html):
    parser=Blocks()
    parser.feed(html)
    days={}
    current=None
    listed=False
    for tag,text in parser.blocks:
        if tag in ("h2","h3"):
            match=re.search(r"([a-z]+ \d{1,2}, 20\d\d)",text)
            current=None
            listed=False
            if match:
                try:
                    current=dt.datetime.strptime(match[1],"%B %d, %Y").date().isoformat()
                    days[current]=set()
                except ValueError:
                    pass
        elif current:
            if tag=="p":
                listed="other sfmta parking programs will not be enforced" in text
            if "will not be enforced" in text or (tag=="li" and listed):
                for fragment,key in [("parking meters","paid"),("nightly street sweeping","nightSweep"),("daytime street sweeping","daySweep"),("residential parking permit","residential"),("general parking time limits","limit")]:
                    if fragment in text:
                        days[current].add(key)
    return days
