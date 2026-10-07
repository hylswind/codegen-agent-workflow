#!/usr/bin/env python3
"""Patch AWS's attestable appliance.kiwi: set the image name and add runtime packages.

Touches nothing else. Refuses to continue if the description has no <ignore> entries or if any
<ignore> entry disappeared after patching (those entries keep ssh/ssm/cloud-init/instance-connect
out of the image).

usage: customize-description.py <appliance.kiwi> --name <image-name> [--add-packages PKG ...]
"""
import argparse
import sys
import xml.etree.ElementTree as ET


def ignores(root):
    return sorted(e.get("name") for e in root.iter("ignore"))


ap = argparse.ArgumentParser()
ap.add_argument("kiwi_file")
ap.add_argument("--name", required=True)
ap.add_argument("--add-packages", nargs="*", default=[])
args = ap.parse_args()

tree = ET.parse(args.kiwi_file)
root = tree.getroot()
before = ignores(root)
if not before:
    sys.exit("refusing: description has no <ignore> entries (expected AWS's attestable example)")

root.set("name", args.name)

image_pkgs = next((p for p in root.findall("packages") if p.get("type") == "image"), None)
if image_pkgs is None:
    sys.exit('refusing: no <packages type="image"> section')
existing = {p.get("name") for p in image_pkgs.findall("package")}
added = []
for name in args.add_packages:
    if name in existing:
        continue
    el = ET.SubElement(image_pkgs, "package")
    el.set("name", name)
    el.tail = "\n        "
    added.append(name)

tree.write(args.kiwi_file, encoding="utf-8", xml_declaration=True)

after = ignores(ET.parse(args.kiwi_file).getroot())
if after != before:
    sys.exit(f"refusing: <ignore> entries changed: {before} -> {after}")

print(f"image name: {args.name}")
print(f"added packages: {', '.join(added) if added else 'none'}")
print(f"preserved ignores: {', '.join(before)}")
