"""Compare two completed MATLAB v7.3 chunks through the HDF5 C library.

No MATLAB process, numpy, scipy, or h5py is required. Read one field from each
file at a time; compare numeric/logical types, shapes, and values exactly,
treating NaNs as equal. Character metadata differences are reported separately.
Only invoke after the receiver has finished writing the new chunk.
"""
from __future__ import annotations

import argparse
import ctypes as c
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import sys
import time


class HDF5:
    def __init__(self, library):
        self.directory = os.add_dll_directory(str(library.parent))
        self.lib = c.CDLL(str(library))
        self.hid = c.c_int64
        self.hsize = c.c_uint64
        signatures = {
            "H5open": (c.c_int, []),
            "H5Fopen": (self.hid, [c.c_char_p, c.c_uint, self.hid]),
            "H5Fclose": (c.c_int, [self.hid]),
            "H5Gopen2": (self.hid, [self.hid, c.c_char_p, self.hid]),
            "H5Gclose": (c.c_int, [self.hid]),
            "H5Gget_num_objs": (c.c_int, [self.hid, c.POINTER(self.hsize)]),
            "H5Gget_objname_by_idx": (c.c_ssize_t, [self.hid, self.hsize, c.c_char_p, c.c_size_t]),
            "H5Gget_objtype_by_idx": (c.c_int, [self.hid, self.hsize]),
            "H5Dopen2": (self.hid, [self.hid, c.c_char_p, self.hid]),
            "H5Dclose": (c.c_int, [self.hid]),
            "H5Dget_type": (self.hid, [self.hid]),
            "H5Dget_space": (self.hid, [self.hid]),
            "H5Dread": (c.c_int, [self.hid, self.hid, self.hid, self.hid, self.hid, c.c_void_p]),
            "H5Sget_simple_extent_ndims": (c.c_int, [self.hid]),
            "H5Sget_simple_extent_dims": (c.c_int, [self.hid, c.POINTER(self.hsize), c.POINTER(self.hsize)]),
            "H5Sget_simple_extent_npoints": (c.c_int64, [self.hid]),
            "H5Sclose": (c.c_int, [self.hid]),
            "H5Tget_class": (c.c_int, [self.hid]),
            "H5Tget_size": (c.c_size_t, [self.hid]),
            "H5Tget_order": (c.c_int, [self.hid]),
            "H5Tget_sign": (c.c_int, [self.hid]),
            "H5Tget_nmembers": (c.c_int, [self.hid]),
            "H5Tget_member_name": (c.c_void_p, [self.hid, c.c_uint]),
            "H5Tget_member_type": (self.hid, [self.hid, c.c_uint]),
            "H5Tget_member_offset": (c.c_size_t, [self.hid, c.c_uint]),
            "H5Tget_super": (self.hid, [self.hid]),
            "H5Tequal": (c.c_int, [self.hid, self.hid]),
            "H5Tclose": (c.c_int, [self.hid]),
            "H5Aexists": (c.c_int, [self.hid, c.c_char_p]),
            "H5Aopen": (self.hid, [self.hid, c.c_char_p, self.hid]),
            "H5Aget_type": (self.hid, [self.hid]),
            "H5Aget_space": (self.hid, [self.hid]),
            "H5Aread": (c.c_int, [self.hid, self.hid, c.c_void_p]),
            "H5Aclose": (c.c_int, [self.hid]),
            "H5Rdereference2": (self.hid, [self.hid, self.hid, c.c_int, c.c_void_p]),
            "H5Iget_type": (c.c_int, [self.hid]),
            "H5Oclose": (c.c_int, [self.hid]),
            "H5free_memory": (c.c_int, [c.c_void_p]),
        }
        for name, (restype, argtypes) in signatures.items():
            function = getattr(self.lib, name)
            function.restype, function.argtypes = restype, argtypes
        self.check(self.lib.H5open(), "initialize HDF5")

    @staticmethod
    def check(value, what):
        if value < 0:
            raise RuntimeError("HDF5 failed to "+what)
        return value

    def open(self, path):
        kernel = c.WinDLL("kernel32", use_last_error=True)
        kernel.GetShortPathNameW.argtypes = [c.c_wchar_p, c.c_wchar_p, c.c_uint]
        kernel.GetShortPathNameW.restype = c.c_uint
        output = c.create_unicode_buffer(32768)
        path = str(path.resolve())
        short = output.value if kernel.GetShortPathNameW(path, output, len(output)) else path
        return self.check(self.lib.H5Fopen(short.encode("utf-8"), 0, 0), "open "+path)

    def children(self, group):
        count = self.hsize()
        self.check(self.lib.H5Gget_num_objs(group, c.byref(count)), "list group")
        output = {}
        for index in range(count.value):
            size = self.check(self.lib.H5Gget_objname_by_idx(group, index, None, 0), "measure name")
            name = c.create_string_buffer(size+1)
            self.check(self.lib.H5Gget_objname_by_idx(group, index, name, size+1), "read name")
            output[name.value.decode("utf-8")] = self.lib.H5Gget_objtype_by_idx(group, index)
        return output

    def attribute(self, obj, name):
        encoded = name.encode("ascii")
        if self.lib.H5Aexists(obj, encoded) <= 0:
            return None
        attribute = self.check(self.lib.H5Aopen(obj, encoded, 0), "open attribute")
        datatype, space = self.lib.H5Aget_type(attribute), self.lib.H5Aget_space(attribute)
        try:
            count = self.lib.H5Sget_simple_extent_npoints(space)
            size = self.lib.H5Tget_size(datatype)*count
            buffer = c.create_string_buffer(size)
            self.check(self.lib.H5Aread(attribute, datatype, buffer), "read attribute")
            raw = buffer.raw
            if self.lib.H5Tget_class(datatype) == 3:
                return raw.rstrip(b"\0").decode("utf-8", errors="replace")
            return list(raw)
        finally:
            self.lib.H5Sclose(space)
            self.lib.H5Tclose(datatype)
            self.lib.H5Aclose(attribute)

    def description(self, datatype):
        kind, size = self.lib.H5Tget_class(datatype), self.lib.H5Tget_size(datatype)
        description = {"hdfClass": kind, "sizeBytes": size}
        if kind in (0, 1):
            order = self.lib.H5Tget_order(datatype)
            description["byteOrder"] = {0: "little", 1: "big"}.get(order, str(order))
            if order not in (0, 1):
                raise ValueError("Unsupported numeric byte order")
            if kind == 0:
                sign = self.lib.H5Tget_sign(datatype)
                description["signed"] = sign == 1
                formats = {1: "b", 2: "h", 4: "i", 8: "q"}
                format_code = formats.get(size)
                if format_code and sign == 0:
                    format_code = format_code.upper()
            else:
                format_code = {4: "f", 8: "d"}.get(size)
            if not format_code:
                raise ValueError("Unsupported numeric size: "+str(size))
            description["format"] = ("<" if order == 0 else ">")+format_code
        elif kind == 6:
            members = []
            for index in range(self.lib.H5Tget_nmembers(datatype)):
                name_pointer = self.lib.H5Tget_member_name(datatype, index)
                try:
                    name = c.string_at(name_pointer).decode("utf-8")
                finally:
                    self.lib.H5free_memory(name_pointer)
                member_type = self.lib.H5Tget_member_type(datatype, index)
                try:
                    members.append({"name": name, "offset": self.lib.H5Tget_member_offset(datatype, index),
                                    "type": self.description(member_type)})
                finally:
                    self.lib.H5Tclose(member_type)
            description["members"] = members
        elif kind == 8:
            base = self.lib.H5Tget_super(datatype)
            try:
                description["base"] = self.description(base)
            finally:
                self.lib.H5Tclose(base)
        return description

    def dataset(self, dataset, maximum):
        datatype = self.lib.H5Dget_type(dataset)
        space = self.lib.H5Dget_space(dataset)
        try:
            rank = self.lib.H5Sget_simple_extent_ndims(space)
            dimensions = (self.hsize*rank)()
            self.check(self.lib.H5Sget_simple_extent_dims(space, dimensions, None), "read dimensions")
            count = self.lib.H5Sget_simple_extent_npoints(space)
            description = self.description(datatype)
            size = count*description["sizeBytes"]
            if size > maximum:
                raise ValueError(f"Field exceeds memory cap: {size} bytes > {maximum}")
            buffer = c.create_string_buffer(size)
            self.check(self.lib.H5Dread(dataset, datatype, 0, 0, 0, buffer), "read dataset")
            metadata = {"hdfShape": list(dimensions), "matlabClass": self.attribute(dataset, "MATLAB_class"),
                        "matlabEmpty": self.attribute(dataset, "MATLAB_empty"), "datatype": description,
                        "storedElementCount": count, "bytesRead": size}
            return metadata, buffer.raw, datatype
        except Exception:
            self.lib.H5Tclose(datatype)
            raise
        finally:
            self.lib.H5Sclose(space)


def numeric_value(raw, offset, datatype):
    kind = datatype["hdfClass"]
    if kind in (0, 1):
        return struct.unpack_from(datatype["format"], raw, offset)[0]
    if kind == 8:
        return numeric_value(raw, offset, datatype["base"])
    if kind == 6:
        return tuple(numeric_value(raw, offset+m["offset"], m["type"]) for m in datatype["members"])
    raise ValueError("Unsupported numeric HDF datatype: "+str(kind))


def equal_value(a, b):
    if isinstance(a, tuple):
        return len(a) == len(b) and all(equal_value(x, y) for x, y in zip(a, b))
    return a == b or (isinstance(a, float) and isinstance(b, float) and math.isnan(a) and math.isnan(b))


def printable(value):
    if isinstance(value, tuple):
        return [printable(v) for v in value]
    if isinstance(value, float) and not math.isfinite(value):
        return str(value)
    return value


class Comparison:
    def __init__(self, hdf, maximum):
        self.hdf, self.maximum = hdf, maximum
        self.numeric, self.metadata, self.errors = [], [], []

    def group(self, left, right, path):
        a, b = self.hdf.children(left), self.hdf.children(right)
        if a != b:
            self.errors.append({"field": path, "error": "Group field names/object kinds differ", "old": a, "new": b})
        for name in sorted(a.keys() & b.keys()):
            child = path+"/"+name
            if a[name] != b[name]:
                continue
            if a[name] == 0:
                x, y = self.hdf.lib.H5Gopen2(left, name.encode(), 0), self.hdf.lib.H5Gopen2(right, name.encode(), 0)
                try:
                    self.group(x, y, child)
                finally:
                    self.hdf.lib.H5Gclose(x)
                    self.hdf.lib.H5Gclose(y)
            elif a[name] == 1:
                x, y = self.hdf.lib.H5Dopen2(left, name.encode(), 0), self.hdf.lib.H5Dopen2(right, name.encode(), 0)
                try:
                    self.dataset(x, y, child)
                except Exception as exc:
                    self.errors.append({"field": child, "error": str(exc)})
                finally:
                    self.hdf.lib.H5Dclose(x)
                    self.hdf.lib.H5Dclose(y)
            else:
                self.errors.append({"field": child, "error": "Unsupported HDF object kind"})

    def dataset(self, left, right, path):
        a, raw_a, type_a = self.hdf.dataset(left, self.maximum)
        try:
            b, raw_b, type_b = self.hdf.dataset(right, self.maximum)
            try:
                same_shape = a["hdfShape"] == b["hdfShape"] and a["matlabEmpty"] == b["matlabEmpty"]
                same_type = self.hdf.lib.H5Tequal(type_a, type_b) > 0 and a["matlabClass"] == b["matlabClass"]
                row = {"field": path, "old": a, "new": b, "sameShape": same_shape, "sameType": same_type,
                       "storageBytesEqual": raw_a == raw_b}
                kind = a["datatype"]["hdfClass"]
                if kind == 7 and b["datatype"]["hdfClass"] == 7:
                    if not same_shape or not same_type:
                        self.errors.append({"field": path, "error": "Reference array shape/type differs"})
                        return
                    size = a["datatype"]["sizeBytes"]
                    for index in range(a["storedElementCount"]):
                        ref_a = c.create_string_buffer(raw_a[index*size:(index+1)*size])
                        ref_b = c.create_string_buffer(raw_b[index*size:(index+1)*size])
                        x = self.hdf.check(self.hdf.lib.H5Rdereference2(left, 0, 0, ref_a), "dereference old")
                        y = self.hdf.check(self.hdf.lib.H5Rdereference2(right, 0, 0, ref_b), "dereference new")
                        try:
                            kx, ky = self.hdf.lib.H5Iget_type(x), self.hdf.lib.H5Iget_type(y)
                            reference_path = f"{path}[{index}]"
                            if kx == ky == 2:  # H5I_GROUP
                                self.group(x, y, reference_path)
                            elif kx == ky == 5:  # H5I_DATASET
                                self.dataset(x, y, reference_path)
                            else:
                                raise ValueError("Unsupported or differing referenced object type")
                        finally:
                            self.hdf.lib.H5Oclose(x)
                            self.hdf.lib.H5Oclose(y)
                    return
                if a["matlabClass"] == "char" or b["matlabClass"] == "char" or kind == 3:
                    row["equal"] = same_shape and same_type and raw_a == raw_b
                    if kind in (0, 1) and a["matlabClass"] == "char":
                        for key, metadata, raw in [("oldText", a, raw_a), ("newText", b, raw_b)]:
                            row[key] = "".join(chr(numeric_value(raw, i*metadata["datatype"]["sizeBytes"], metadata["datatype"]))
                                              for i in range(metadata["storedElementCount"]))
                    self.metadata.append(row)
                    return
                if kind not in (0, 1, 6, 8):
                    raise ValueError("Unhandled field; cannot claim numeric coverage: HDF class "+str(kind))
                if a["storedElementCount"] == b["storedElementCount"] == 1 and same_type:
                    row["oldScalar"] = printable(numeric_value(raw_a, 0, a["datatype"]))
                    row["newScalar"] = printable(numeric_value(raw_b, 0, b["datatype"]))
                mismatches, examples = 0, []
                if same_shape and same_type:
                    if raw_a != raw_b:
                        size = a["datatype"]["sizeBytes"]
                        for index in range(a["storedElementCount"]):
                            av = numeric_value(raw_a, index*size, a["datatype"])
                            bv = numeric_value(raw_b, index*size, b["datatype"])
                            if not equal_value(av, bv):
                                mismatches += 1
                                if len(examples) < 8:
                                    examples.append({"storedFlatIndexZeroBased": index, "old": printable(av), "new": printable(bv)})
                    row["numericValuesEqual"] = mismatches == 0
                    row["mismatchedStoredElements"] = mismatches
                    row["firstDifferences"] = examples
                else:
                    row["numericValuesEqual"] = False
                row["equal"] = same_shape and same_type and row["numericValuesEqual"]
                self.numeric.append(row)
            finally:
                self.hdf.lib.H5Tclose(type_b)
        finally:
            self.hdf.lib.H5Tclose(type_a)


def snapshot(path):
    stat = path.stat()
    return {"path": str(path.resolve()), "sizeBytes": stat.st_size, "mtimeNs": stat.st_mtime_ns}


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as f:
        while block := f.read(1024*1024):
            result.update(block)
    return result.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("old", type=Path)
    parser.add_argument("new", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--hdf5-library", type=Path, default=Path("C:/Program Files/MATLAB/R2024b/bin/win64/hdf5.dll"))
    parser.add_argument("--max-field-mib", type=int, default=32)
    parser.add_argument("--minimum-age-seconds", type=float, default=5)
    args = parser.parse_args()
    output = args.output or args.new.with_name(args.new.stem+"_reproduction_verification.json")
    if output.resolve() in (args.old.resolve(), args.new.resolve()):
        raise SystemExit("Output JSON must not overwrite either source MAT file.")
    before_a, before_b = snapshot(args.old), snapshot(args.new)
    for info in (before_a, before_b):
        if time.time()-info["mtimeNs"]/1e9 < args.minimum_age_seconds:
            raise SystemExit("Refusing a recently modified file; confirm chunk writing has finished before retrying.")
    hdf = HDF5(args.hdf5_library)
    comparison = Comparison(hdf, args.max_field_mib*1024*1024)
    left, right = hdf.open(args.old), hdf.open(args.new)
    try:
        x = hdf.check(hdf.lib.H5Gopen2(left, b"chunk", 0), "open old chunk")
        y = hdf.check(hdf.lib.H5Gopen2(right, b"chunk", 0), "open new chunk")
        try:
            comparison.group(x, y, "chunk")
        finally:
            hdf.lib.H5Gclose(x)
            hdf.lib.H5Gclose(y)
    finally:
        hdf.lib.H5Fclose(left)
        hdf.lib.H5Fclose(right)
    before_a["sha256"] = digest(args.old)
    before_b["sha256"] = digest(args.new)
    unchanged = all(all(snapshot(path)[key] == info[key] for key in ("sizeBytes", "mtimeNs"))
                    for path, info in [(args.old, before_a), (args.new, before_b)])
    unequal = [r["field"] for r in comparison.numeric if not r["equal"]]
    result = {
        "generatedUtc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "ok": bool(comparison.numeric) and not unequal and not comparison.errors and unchanged,
        "old": before_a, "new": before_b, "sourceFilesUnchangedDuringComparison": unchanged,
        "matlabLaunched": False, "hdf5Library": str(args.hdf5_library),
        "method": "Every numeric/logical dataset reachable from chunk; exact type/shape/value equality, NaNs equal, signed zeros numerically equal; one field pair at a time. HDF reference addresses are dereferenced, not compared.",
        "limits": "Validates this saved chunk, not every tracking epoch or all channels. Character metadata is reported separately. File age and stable size/mtime are guards, not a substitute for the caller confirming completed writes.",
        "maximumBytesPerField": args.max_field_mib*1024*1024,
        "numericFieldsCompared": len(comparison.numeric), "numericFieldsUnequal": unequal,
        "metadataFieldsCompared": len(comparison.metadata),
        "metadataFieldsUnequal": [r["field"] for r in comparison.metadata if not r["equal"]],
        "numericFields": comparison.numeric, "metadataFields": comparison.metadata, "errors": comparison.errors,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False), encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k not in ("numericFields", "metadataFields")}, ensure_ascii=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
