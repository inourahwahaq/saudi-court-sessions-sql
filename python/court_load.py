"""Download the 2026 monthly court session files and load them into SQLite.

usage: python3 court_load.py <raw_dir> <database.db>
"""
import csv
import json
import sqlite3
import sys
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://open.data.gov.sa/data/api/datasets/resources?version=-1&dataset="
DATASETS = {
    "2026_01": "7d7530ed-52ec-4b10-8d46-a5efc587947a", "2026_02": "a0ec1732-4a58-4c34-9a8b-f704271ac178", "2026_03": "ef755769-3709-499f-9683-109d20345abd",
    "2026_04": "41a8bd75-0f92-4e5d-95ff-e2297156d7c1", "2026_05": "f65cdf90-c95b-48e9-b7d5-082e201195a9", "2026_06": "74c50d59-6902-4076-b869-2cc830a8d005",
    "2026_07": "1ee635af-82ed-4575-a3bc-02bbcebbb642", "2026_08": "6e4ac88e-27e9-4bdd-b910-21110c35cecb", "2026_09": "8b723af1-44e3-4b39-9545-1343b1e24ba9",
}
FIELDS = ["المنطقة", "المدينة", "تصنيف القضية", "تاريخ الجلسة ميلادي", "تاريخ الجلسة هجري", "الرقم المرجعي"]


def get(url):
    request = urllib.request.Request(url, headers={"User-Agent": "data-analysis"})
    with urllib.request.urlopen(request, timeout=240) as response:
        return response.read()


# Create an empty database
raw_dir, db = Path(sys.argv[1]), Path(sys.argv[2])
raw_dir.mkdir(parents=True, exist_ok=True)
db.unlink(missing_ok=True)
con = sqlite3.connect(db)
con.execute("CREATE TABLE raw_sessions (region_ar TEXT, city_ar TEXT, case_type_ar TEXT, session_date TEXT, session_date_hijri TEXT, reference_no TEXT, source_month TEXT)")

# Download each month if needed and load it
for month, dataset in DATASETS.items():
    path = raw_dir / f"{month}.csv"
    if not path.exists():
        resources = json.loads(get(API + dataset))["resources"]
        url = next(r["downloadUrl"] for r in resources if r["format"] == "CSV")
        path.write_bytes(get(urllib.parse.quote(url, safe=":/")))
    with open(path, encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)
        header = [h.strip() for h in next(reader)]
        positions = [header.index(field) for field in FIELDS]
        rows = [[r[i].strip() for i in positions] + [month] for r in reader if len(r) == len(header) and any(x.strip() for x in r)]
    con.executemany("INSERT INTO raw_sessions VALUES (?,?,?,?,?,?,?)", rows)

con.commit()
con.close()
