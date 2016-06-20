module fat12_driver;

import STD_ARRAY = std.array;
import std.algorithm.mutation;
import std.stdio;
import std.string;

import util;

alias ClusterId = ushort;
alias SectorId = ushort;

struct Fat12 {
	static SectorId BOOT_SECTOR = 0;
	static SectorId FAT1_SECTOR, FAT2_SECTOR, ROOT_DIR_SECTOR;
	static this() {
		FAT1_SECTOR = cast(ushort)(BOOT_SECTOR + 1);
		FAT2_SECTOR = cast(ushort)(FAT1_SECTOR + 9);
		ROOT_DIR_SECTOR = cast(ushort)(FAT2_SECTOR + 9);
	}

	File image;
	ImageConfig config;

	this(File f) {
		image = f;
		config = ImageConfig(f);
	}

	ubyte[] readSector(SectorId sectorNum) {
		image.seek(sectorNum * config.bytesPerSector);
		return image.rawRead(new ubyte[config.bytesPerSector]);
	}

	ubyte[] readClusterData(ClusterId clusterNum) {
		return readSector(cast(ushort)(clusterNum + 33 - 2));
	}

	ClusterId readFatValue(ClusterId clusterNum) {
		// 512 / 2 = 256 values per sector, so ignore the last byte
		auto sector = readSector(FAT1_SECTOR + clusterNum >> 8);
		// the index within the sector is what we just ignored
		return sector.getWordAt((clusterNum && 0xff) << 1);
	}

	/// returns the directory entry of a file with matching filename
	/// note: doesn't support directories
	DirectoryEntry fileEntry(string fn)
	out (entry) {
		assert(!entry.isFree);
		assert(!entry.restAreFree);
	} body {
		seekSector(ROOT_DIR_SECTOR);
		auto entryBytes = new ubyte[DirectoryEntry.sizeof];
		while (true) {
			auto entry = DirectoryEntry(image.rawRead(entryBytes));
			if (entry.restAreFree) {
				break;
			} else if (entry.isFree) {
				continue;
			}

			if (entry.filename == fn) {
				return entry;
			}
		}
		throw new Exception("file %s not found", fn);
	}

	bool fileExists(string fn) {
		try {
			fileEntry(fn);
			return true;
		} catch {
			return false;
		}
	}

	private void seekSector(SectorId sectorNum) {
		image.seek(sectorNum * config.bytesPerSector);
	}
}

struct ImageConfig {
	char[8] oem;
	ushort bytesPerSector;
	ubyte sectorsPerCluster;
	ushort reservedSectors;
	ubyte numberOfFats;
	ushort rootEntries;
	ushort totalSectors;
	ubyte media;
	ushort sectorsPerFat;
	ushort sectorsPerTrack;
	ushort headsPerCylinder;
	uint hiddenSectors;
	uint totalSectorsBig;
	ubyte driveNumber;
	ubyte unused;
	ubyte extBootSignature;
	uint serialNumber;
	char[11] volumeLabel;
	char[8] fileSystem;

	this(File img) {
		// rewind to start
		img.rewind();
		auto header = img.rawRead(new ubyte[62]);
		bytesPerSector = header.getWordAt(11);
		sectorsPerCluster = header[13];
		reservedSectors = header.getWordAt(14);
		numberOfFats = header[16];
		rootEntries = header.getWordAt(17);
		totalSectors = header.getWordAt(19);
		media = header[21];
		sectorsPerFat = header.getWordAt(22);
		sectorsPerTrack = header.getWordAt(24);
		headsPerCylinder = header.getWordAt(26);
		hiddenSectors = header.getDoubleAt(28);
		totalSectorsBig = header.getDoubleAt(32);
		driveNumber = header[36];
		unused = header[37];
		extBootSignature = header[38];
		serialNumber = header.getDoubleAt(39);
		copy(volumeLabel, cast(char[])header[43..54]);
		copy(fileSystem, cast(char[])header[54..62]);
	}
}

private ushort getWordAt(ubyte[] data, size_t index) {
	return cast(ushort)(data[index + 1] << 8 + data[index]);
}

private uint getDoubleAt(ubyte[] data, size_t index) {
	return cast(uint)(
		data[index] +
		data[index + 1] << 8 +
		data[index + 2] << 16 +
		data[index + 3] << 24
	);
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

struct DirectoryEntry {
	ubyte[8] filename;
	ubyte[3] extension;
	ubyte attributes;
	ushort reserved;
	ushort creationTime;
	ushort creationDate;
	ushort lastAccessDate;
	ushort IGNORE_IN_FAT12;
	ushort lastWirteTime;
	ushort lastWriteDate;
	ushort firstLogicalCluster;
	uint fileSize; // in bytes

	@property const bool isFree() {
		return filename[0] == 0xe5 || filename[0] == 0;
	}

	@property const bool restAreFree() {
		return filename[0] == 0;
	}

	this(ubyte[] data) {
		copy(filename, data[0..8]);
		copy(extension, data[8..11]);
		attributes = data[11];
		reserved = data.getWordAt(12);
		creationTime = data.getWordAt(14);
		creationDate = data.getWordAt(16);
		lastAccessDate = data.getWordAt(18);
		IGNORE_IN_FAT12 = data.getWordAt(20);
		lastWirteTime = data.getWordAt(22);
		lastWriteDate = data.getWordAt(24);
		firstLogicalCluster = data.getWordAt(26);
		fileSize = data.getDoubleAt(28); // in bytes
	}
}
unittest {
	assert(DirectoryEntry.sizeof == 32);
}
