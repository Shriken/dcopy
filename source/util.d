module util;

import STD_ARRAY = std.array;
import std.stdio;
import std.string;

T popFront(T)(ref T[] arr) {
	T x = arr[0];
	arr = arr[1..$];
	return x;
}

// format a filename to fat12
// trim the name if it's too long
// extend it with spaces if it's too short
string formatFilename(string fn) {
	string ret = fn;
	auto index = ret.lastIndexOf('.');
	if (index != ret.length - 3) {
		if (ret.indexOf('.') == -1) {
			ret ~= '.';
			index = ret.length - 1;
		}
		ret ~= STD_ARRAY.replicate(" ", 4 - (ret.length - index));
	}

	if (ret.length > 12) {
		ret = ret[0..8] ~ ret[$-3..$];
	} else if (ret.length < 12) {
		auto separator = ret.lastIndexOf('.');
		ret = ret[0..separator]
			~ STD_ARRAY.replicate(" ", 8 - separator)
			~ ret[$-3..$];
	}

	debug {
		if (fn != ret) {
			stderr.writefln(
				"warning: changed fn \"%s\" to \"%s\"",
				fn,
				ret
			);
		}
	}

	return ret;
}
