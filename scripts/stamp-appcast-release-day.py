import datetime
import email.utils
import plistlib
import sys
import xml.etree.ElementTree as ET
import zipfile


class ReleaseDayStamp:
    @staticmethod
    def run(archive_path, appcast_path):
        with zipfile.ZipFile(archive_path) as archive:
            info = plistlib.loads(archive.read("supacode.app/Contents/Info.plist"))
        day = datetime.date.fromisoformat(info["SupacodeReleaseDay"])
        published = datetime.datetime.combine(day, datetime.time(tzinfo=datetime.UTC))
        namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
        ET.register_namespace("sparkle", namespace)
        tree = ET.parse(appcast_path)
        matched = False
        for item in tree.findall(".//item"):
            enclosure = item.find("enclosure")
            if enclosure is not None:
                filename = enclosure.get("url", "").rsplit("/", 1)[-1]
                if filename.startswith("supacode-v") and filename.endswith(".app.zip"):
                    tag = filename.removeprefix("supacode-").removesuffix(".app.zip")
                    enclosure.set("url", f"https://supacode.sh/download/{tag}/supacode.app.zip")
            version = item.find(f"{{{namespace}}}version")
            if version is not None and version.text == str(info["CFBundleVersion"]):
                date = item.find("pubDate")
                if date is None:
                    date = ET.SubElement(item, "pubDate")
                date.text = email.utils.format_datetime(published, usegmt=True)
                matched = True
        if not matched:
            raise ValueError("The appcast does not contain the archived build")
        tree.write(appcast_path, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    ReleaseDayStamp.run(*sys.argv[1:])
