"""Run analysis.sql against the SQLite database and write each @export block to CSV.
usage: python3 run_analysis.py <database.db> <analysis.sql> <output_dir>
"""
import csv
import os
import re
import sqlite3
import sys

db, sql_path, out = sys.argv[1:4]
os.makedirs(out, exist_ok=True)
text = open(sql_path, encoding="utf-8").read()
parts = re.split(r"^-- @export (\w+)\s*$", text, flags=re.M)

con = sqlite3.connect(db)
con.executescript(parts[0])
for i in range(1, len(parts), 2):
    name, body = parts[i], parts[i + 1]
    # An export block is one SELECT; anything after its semicolon is setup for later blocks.
    end = body.index(";")
    query, rest = body[:end], body[end + 1:]
    cur = con.execute(query)
    rows = cur.fetchall()
    with open(f"{out}/{name}.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow([c[0] for c in cur.description])
        w.writerows(rows)
    print(name, len(rows))
    if rest.strip():
        con.executescript(rest)
con.commit()
con.close()
