import STD_ARRAY = std.array;
import std.getopt;
import std.stdio;
import std.string;
import std.typecons;

import util;

int main(string[] args) {
	auto name = args[0];
	bool sourceIsStdin = false;
	auto helpInfo = getopt(
		args,
		"stdin|i", "Read from stdin.", &sourceIsStdin,
	);

	// ensure args were properly formatted
	auto argError = args.length < 4 - sourceIsStdin ? 1 : 0;
	if (argError || helpInfo.helpWanted) {
		usage(name);
		defaultGetoptPrinter("options:", helpInfo.options);
		return argError ? 1 : 0;
	}

	// open source and target
	File source, target;
	try {
		args.popFront();
		openSourceAndTarget(args, sourceIsStdin, source, target);
	} catch (Exception e) {
		writeln(e.msg);
		return 1;
	}

	auto path = args.popFront().formatFilenameToFAT12();

	return 0;
}

// open two files as specified by the usage
// also cleanse them from the args
void openSourceAndTarget(
	ref string[] names,
	bool sourceIsStdin,
	File source,
	File target
) {
	// open source and target files
	if (sourceIsStdin) {
		source = stdin;
	} else {
		source = File(names.popFront());
	}
	target = File(names.popFront(), "w");
}

// format a filename to fat12
// trim the name if it's too long
// extend it with spaces if it's too short
string formatFilenameToFAT12(string fn) {
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
		ret = ret[0..8] ~ '.' ~ ret[$-3..$];
	} else if (ret.length < 12) {
		auto separator = ret.lastIndexOf('.');
		ret = ret[0..separator]
			~ STD_ARRAY.replicate(" ", 8 - separator)
			~ '.'
			~ ret[$-3..$];
	}

	if (fn != ret) {
		stderr.writefln("warning: changed fn \"%s\" to \"%s\"", fn, ret);
	}

	return ret;
}

void usage(string name) {
	writefln("usage: %s (-i|--stdin|source) target path\n", name);
}
