module fat12_driver;

import std.algorithm.mutation;
import std.stdio;

import util;

alias ClusterId = ushort;
alias SectorId = ushort;
bool isLastCluster(ClusterId cluster) {
	return 0xff8 <= cluster && cluster <= 0xfff;
}

static SectorId BOOT_SECTOR = 0;
static SectorId FAT1_SECTOR, FAT2_SECTOR, ROOT_DIR_SECTOR;
static this() {
	FAT1_SECTOR = cast(ushort)(BOOT_SECTOR + 1);
	FAT2_SECTOR = cast(ushort)(FAT1_SECTOR + 9);
	ROOT_DIR_SECTOR = cast(ushort)(FAT2_SECTOR + 9);
}

struct Fat12 {
	Image image;

	this(File f) {
		image = new Image(f);
	}
}

class Image {
	File file;
	ImageConfig config;

	this(File f) {
		file = f;
		config = ImageConfig(f);
	}

	ubyte[] readSector(SectorId sectorNum) {
		seekSector(sectorNum);
		return file.rawRead(new ubyte[config.bytesPerSector]);
	}

	void writeSector(SectorId sectorNum, ubyte[] data)
	in {
		assert(data.length <= config.bytesPerSector);
	} body {
		seekSector(sectorNum);
		file.rawWrite(data);
	}

	private void seekSector(SectorId sectorNum) {
		file.seek(sectorNum * config.bytesPerSector);
	}
}

struct Cluster {
	ClusterId id;
	ClusterId value;
	ubyte[512] data;

	private Image image;
	@property SectorId dataSector() { return cast(ushort)(id + 33 - 2); }

	this(ClusterId id, Image image) {
		this.image = image;
		this.id = id;
		this.value = readFatValue(id);
		this.data = image.readSector(cast(ushort)(id + 33 - 2));
	}

	~this() {
		writeFatValue(value);
		image.writeSector(dataSector, data);
	}

	private ClusterId readFatValue(ClusterId clusterNum) {
		// locate the value
		auto valueStart = (clusterNum * 3) / 2; // byte offset
		auto startingSector = 33 + (valueStart >> 9) - 2;
		auto indexInSector = valueStart % 512;

		// get first and second bytes
		ubyte firstHalf, secondHalf;
		auto bytes = image.readSector(cast(ushort)startingSector);
		firstHalf = bytes[indexInSector];
		if (indexInSector == 511) {
			bytes = image.readSector(cast(ushort)(startingSector + 1));
			secondHalf = bytes[0];
		} else {
			secondHalf = bytes[indexInSector + 1];
		}

		auto odd = clusterNum % 2 == 1;
		if (odd) {
			return ((firstHalf & 0xf0) << 8) | secondHalf;
		} else {
			return (firstHalf << 4) | (secondHalf & 0xff);
		}
	}

	private void writeFatValue(ClusterId value)
	in {
		assert(value <= 0xfff);
	} body {
		// locate the value
		auto valueStart = (id * 3) / 2; // byte offset
		SectorId startingSector = cast(SectorId)(33 + (valueStart >> 9) - 2);
		auto indexInSector = valueStart & 0x1f;

		auto odd = id % 2 == 1;
		ubyte firstHalf, secondHalf;
		// first half
		auto firstSector = image.readSector(cast(ushort)startingSector);
		if (odd) {
			firstHalf = ((value & 0xf) << 4) |
				(firstSector[indexInSector] & 0xf);
		} else {
			firstHalf = value & 0xff;
		}

		// second half
		ubyte secondByte;
		auto onTheEdge = indexInSector + 1 == firstSector.length;
		ubyte[] secondSector;
		if (onTheEdge) {
			secondSector = image.readSector(cast(ushort)(startingSector + 1));
			secondByte = secondSector[0];
		} else {
			secondByte = firstSector[indexInSector + 1];
		}
		secondHalf = odd ? (value & 0xff0 >> 4)
			: ((secondByte & 0xf0) | (value >> 8));

		// store
		firstSector[indexInSector] = firstHalf;
		if (onTheEdge) {
			secondSector[0] = secondHalf;
			image.writeSector(cast(SectorId)(startingSector + 1), secondSector);
		} else {
			firstSector[indexInSector + 1] = secondHalf;
		}
		image.writeSector(startingSector, firstSector);
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

struct DirectoryEntry {
	static ubyte FREE_BYTE = 0xe5;
	static ubyte REST_ARE_FREE_BYTE = 0;

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
		return filename[0] == FREE_BYTE || filename[0] == REST_ARE_FREE_BYTE;
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

	/+
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
			auto entry = DirectoryEntry(file.rawRead(entryBytes));
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
	+/

	unittest {
		assert(DirectoryEntry.sizeof == 32);
	}
}
