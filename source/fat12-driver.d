module fat12_driver;

import std.algorithm.mutation;
import std.array;
import std.stdio;

import util;

alias ClusterId = ushort;
alias SectorId = ushort;
bool isFree(ClusterId val) { return val == 0; }
bool isReserved(ClusterId val) { return 0xff0 <= val && val <= 0xff6; }
bool isBad(ClusterId val) { return val == 0xff7; }
bool isLast(ClusterId val) { return 0xff8 <= val && val <= 0xfff; }
static ClusterId MIN_CLUSTER_ID = 2;
static ClusterId MAX_CLUSTER_ID = 0xb20;

static SectorId BOOT_SECTOR = 0;
static SectorId FAT1_START_SECTOR, FAT2_START_SECTOR;
static SectorId ROOT_DIR_START_SECTOR;
static SectorId DATA_START_SECTOR;
static this() {
	FAT1_START_SECTOR = cast(ushort)(BOOT_SECTOR + 1);
	FAT2_START_SECTOR = cast(ushort)(FAT1_START_SECTOR + 9);
	ROOT_DIR_START_SECTOR = cast(ushort)(FAT2_START_SECTOR + 9);
	DATA_START_SECTOR = cast(ushort)(ROOT_DIR_START_SECTOR + 14);
}

struct Fat12 {
	Image image;

	this(File f) {
		image = new Image(f);
	}
}

class Fat12File {
	FileConfig config;
	ushort entryNum;

	private Image image;
	@property ushort entriesPerSector() {
		return image.config.bytesPerSector / FileConfig.sizeof;
	}

	this(string fn, Image image) {
		this.image = image;

		fn = formatFilename(fn);
		if (!findFile(fn)) {
			if (!getEmptyFileEntry()) {
				throw new Exception("no space on disk");
			}
		}
	}

	~this() {
		// save the file config
		ushort sectorNum = cast(ushort)(entryNum / entriesPerSector);
		auto sector = image.readSector(sectorNum);
		auto entryIndex = entryNum % entriesPerSector;
		auto offset = entryIndex * FileConfig.sizeof;
		config.save(sector[offset .. offset + FileConfig.sizeof]);
		image.writeSector(sectorNum, sector);
	}

	// note: overwrites existing data
	void write(ubyte[] data) {
		auto clusterNum = config.firstLogicalCluster;
		while (true) {
			auto cluster = new Cluster(clusterNum, image);
			cluster.write(data);
			if (data.length <= image.config.bytesPerSector) {
				if (!cluster.value.isFree) {
					clearChain(cluster.value);
				}
				cluster.value = 0xfff;
				break;
			}
			data = data[image.config.bytesPerSector .. $];

			// get next cluster
			if (cluster.value.isLast) {
				cluster.value = image.getFreeCluster();
			}
		}
	}

	void clearChain(ClusterId start) {
		auto cluster = new Cluster(start, image);
		if (!cluster.value.isFree) {
			clearChain(cluster.value);
			cluster.value = 0;
		}
	}

	private bool getEmptyFileEntry() {
		foreach (sectorId; ROOT_DIR_START_SECTOR .. DATA_START_SECTOR) {
			auto sector = image.readSector(sectorId);
			foreach (entryIndex; 0 .. entriesPerSector) {
				auto byteStart = entryIndex * FileConfig.sizeof;
				auto entryBytes = sector[
					byteStart .. byteStart + FileConfig.sizeof
				];
				auto file = FileConfig(entryBytes);
				if (file.isFree) {
					config = file;
					entryNum = cast(ushort)(
						entryIndex + sectorId * entriesPerSector
					);
					return true;
				}
			}
		}
		return false;
	}

	private bool findFile(string fn) {
		foreach (sectorId; ROOT_DIR_START_SECTOR .. DATA_START_SECTOR) {
			auto sector = image.readSector(sectorId);
			foreach (entryIndex; 0 .. entriesPerSector) {
				auto byteStart = entryIndex * FileConfig.sizeof;
				auto entryBytes = sector[
					byteStart .. byteStart + FileConfig.sizeof
				];
				auto file = FileConfig(entryBytes);
				if (file.restAreFree) {
					return false;
				} else if (file.isFree) {
					continue;
				} else if (
					file.filename == fn[0 .. 8]
					&& file.extension == fn [9 .. 12]
				) {
					config = file;
					entryNum = cast(ushort)(
						entryIndex + sectorId * entriesPerSector
					);
					return true;
				}
			}
		}
		return false;
	}
}

class Image {
	File file;
	ImageConfig config;

	this(File f) {
		file = f;
		config = ImageConfig(f);
	}

	ClusterId getFreeCluster() {
		foreach (clusterNum; MIN_CLUSTER_ID .. MAX_CLUSTER_ID) {
			auto value = readFatValue(clusterNum);
			if (value.isFree) {
				return clusterNum;
			}
		}
		throw new Exception("no free clusters");
	}

	ClusterId readFatValue(ClusterId clusterNum) {
		// locate the value
		auto valueStart = (clusterNum * 3) / 2; // byte offset
		auto startingSector = 33 + (valueStart >> 9) - 2;
		auto indexInSector = valueStart % 512;

		// get first and second bytes
		ubyte firstHalf, secondHalf;
		auto bytes = readSector(cast(ushort)startingSector);
		firstHalf = bytes[indexInSector];
		if (indexInSector == 511) {
			bytes = readSector(cast(ushort)(startingSector + 1));
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

	void writeFatValue(ClusterId id, ClusterId value)
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
		auto firstSector = readSector(cast(ushort)startingSector);
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
			secondSector = readSector(cast(ushort)(startingSector + 1));
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
			writeSector(cast(SectorId)(startingSector + 1), secondSector);
		} else {
			firstSector[indexInSector + 1] = secondHalf;
		}
		writeSector(startingSector, firstSector);
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

class Cluster {
	ClusterId id;
	ClusterId value;
	ubyte[512] data;

	private Image image;
	@property SectorId dataSector() { return cast(ushort)(id + 33 - 2); }

	this(ClusterId id, Image image) {
		this.image = image;
		this.id = id;
		this.value = image.readFatValue(id);
		this.data = image.readSector(cast(ushort)(id + 33 - 2));
	}

	~this() {
		image.writeFatValue(id, value);
		image.writeSector(dataSector, data);
	}

	void write(ubyte[] data) {
		auto bps = image.config.bytesPerSector;
		if (data.length > bps) {
			data = data[0 .. bps];
		} else if (data.length < bps) {
			data = data ~ replicate([cast(ubyte)0], bps - data.length);
		}
		this.data = data.dup;
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

struct FileConfig {
	static ubyte FREE_BYTE = 0xe5;
	static ubyte REST_ARE_FREE_BYTE = 0;

	@property const ubyte[8] filename() { return data[0..8]; }
	@property const ubyte[3] extension() { return data[8..11]; }
	@property const ubyte attributes() { return data[11]; }
	@property const ushort reserved() { return data.getWordAt(12); }
	@property const ushort creationTime() { return data.getWordAt(14); }
	@property const ushort creationDate() { return data.getWordAt(16); }
	@property const ushort lastAccessDate() { return data.getWordAt(18); }
	@property const ushort IGNORE_IN_FAT12() { return data.getWordAt(20); }
	@property const ushort lastWirteTime() { return data.getWordAt(22); }
	@property const ushort lastWriteDate() { return data.getWordAt(24); }
	@property const ushort firstLogicalCluster() {
		return data.getWordAt(26);
	}
	@property const uint fileSize() { return data.getDoubleAt(28); } // in bytes

	@property const bool isFree() {
		return filename[0] == FREE_BYTE
			|| filename[0] == REST_ARE_FREE_BYTE;
	}

	@property const bool restAreFree() {
		return filename[0] == REST_ARE_FREE_BYTE;
	}

	private ubyte[] data;

	this(ubyte[] data) {
		this.data = data[0..32].dup();
	}

	void save(ubyte[] dest) {
		copy(dest, data);
	}

	unittest {
		assert(DirectoryEntry.sizeof == 32);
	}
}

private ushort getWordAt(const ubyte[] data, size_t index) {
	return cast(ushort)(data[index + 1] << 8 + data[index]);
}

private uint getDoubleAt(const ubyte[] data, size_t index) {
	return cast(uint)(
		data[index] +
		data[index + 1] << 8 +
		data[index + 2] << 16 +
		data[index + 3] << 24
	);
}
