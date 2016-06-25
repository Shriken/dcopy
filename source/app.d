import std.algorithm.iteration;
import std.file;
import std.getopt;
import std.stdio;
import std.typecons;

import fat12_driver;
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

	auto path = args.popFront();
	auto image = new Image(target);
	auto file = new Fat12File(path, image);
	source.byChunk(image.config.bytesPerSector)
		.each!(c => file.append(c));

	return 0;
}

// open two files as specified by the usage
// also cleanse them from the args
void openSourceAndTarget(
	ref string[] names,
	bool sourceIsStdin,
	out File source,
	out File target
) {
	// open source and target files
	if (sourceIsStdin) {
		source = stdin;
	} else {
		source = File(names.popFront());
	}
	target = File(names.popFront(), "r+");
}

void usage(string name) {
	writefln("usage: %s (-i|--stdin|source) target path\n", name);
}
