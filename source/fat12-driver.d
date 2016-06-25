module fat12_driver;

import std.algorithm.comparison;
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

class Fat12File {
	FileConfig config;
	ushort entryNum;

	private Image image;
	@property ushort entriesPerSector() {
		return image.config.bytesPerSector / FileConfig.sizeof;
	}

	@property private Cluster lastCluster() {
		if (config.firstLogicalCluster.isFree) {
			config.firstLogicalCluster = image.getFreeCluster();
		}

		auto cluster = Cluster(config.firstLogicalCluster, image);
		if (cluster.value.isFree) {
			cluster.value = 0xfff;
		}
		while (!cluster.value.isLast) {
			cluster = Cluster(cluster.value, image);
		}
		return cluster;
	}

	this(string fn, Image image) {
		this.image = image;

		fn = formatFilename(fn);
		assert(fn.length == 11);
		if (!findFile(fn)) {
			if (!getEmptyFileEntry()) {
				throw new Exception("no space on disk");
			}
		}

		auto fnBytes = cast(ubyte[])fn;
		config.filename = fnBytes[0..8];
		config.extension = fnBytes[8..11];
	}

	void saveConfig() {
		debug writeln("saving file config...");
		// save the file config
		ushort sectorNum = cast(ushort)(
			ROOT_DIR_START_SECTOR + entryNum / entriesPerSector
		);
		auto sector = image.readSector(sectorNum);
		auto entryIndex = entryNum % entriesPerSector;
		auto offset = entryIndex * 32;
		config.save(sector[offset .. offset + 32]);
		image.writeSector(sectorNum, sector);
		debug writeln("saved.");
	}

	void append(ubyte[] data) {
		scope(exit) saveConfig();
		debug writeln("appending to file...");
		auto last = lastCluster;

		// first append to end of last cluster
		auto bps = image.config.bytesPerSector;
		auto sizeInLast = config.fileSize % bps;
		auto count = min(data.length, bps - sizeInLast);
		last.data[sizeInLast .. sizeInLast + count] = data[0 .. count];
		config.fileSize = config.fileSize + count;
		data = data[count .. $];
		if (data.length == 0) {
			return;
		}

		// then write to new clusters as needed
		last.value = image.getFreeCluster();
		debug writeln("free cluster gotten, writing");
		write(data, last.value);
		debug writeln("done.");
	}

	// note: overwrites existing data
	void write(ubyte[] data) {
		write(data, config.firstLogicalCluster);
		config.fileSize = cast(uint)data.length;
		saveConfig();
	}

	private void write(ubyte[] data, ClusterId start) {
		debug writeln("writing to file...");
		auto nextCluster = start;
		while (true) {
			debug writeln("\twriting a sector");
			auto cluster = Cluster(nextCluster, image);
			cluster.write(data);
			if (data.length <= image.config.bytesPerSector) {
				if (!cluster.value.isFree) {
					clearChain(cluster.value);
				}
				cluster.value = 0xfff; // set end
				break;
			}
			data = data[image.config.bytesPerSector .. $];

			// get next cluster
			if (cluster.value.isLast) {
				cluster.value = image.getFreeCluster();
			}
			nextCluster = cluster.value;
		}
		writef("written.\n");
	}

	private void clearChain(ClusterId start) {
		auto cluster = Cluster(start, image);
		if (!cluster.value.isFree) {
			clearChain(cluster.value);
			cluster.value = 0;
		}
	}

	private bool getEmptyFileEntry() {
		debug writeln("looking for empty file entry...");
		foreach (sectorId; ROOT_DIR_START_SECTOR .. DATA_START_SECTOR) {
			auto sector = image.readSector(sectorId);
			foreach (entryIndex; 0 .. entriesPerSector) {
				enum FILE_CONFIG_SIZE = 32;
				auto byteStart = entryIndex * FILE_CONFIG_SIZE;
				auto entryBytes = sector[
					byteStart .. byteStart + FILE_CONFIG_SIZE
				];
				auto file = FileConfig(entryBytes);
				if (file.isFree) {
					config = file;
					entryNum = cast(ushort)(
						entryIndex + sectorId * entriesPerSector
					);
					debug writeln("found.");
					return true;
				}
			}
		}
		debug writeln("not found.");
		return false;
	}

	private bool findFile(string fn) {
		debug writefln("looking for file %s...", fn);
		foreach (sectorId; ROOT_DIR_START_SECTOR .. DATA_START_SECTOR) {
			auto sector = image.readSector(sectorId);
			foreach (entryIndex; 0 .. entriesPerSector) {
				enum FILE_CONFIG_SIZE = 32;
				auto byteStart = entryIndex * FILE_CONFIG_SIZE;
				auto entryBytes = sector[
					byteStart .. byteStart + FILE_CONFIG_SIZE
				];
				auto file = FileConfig(entryBytes);
				if (file.restAreFree) {
					debug writeln("not found.");
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
					debug writeln("found.");
					return true;
				}
			}
		}
		debug writeln("not found.");
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
		debug writeln("getting free cluster...");
		foreach (clusterNum; MIN_CLUSTER_ID .. MAX_CLUSTER_ID) {
			auto value = readFatValue(clusterNum);
			if (value.isFree) {
				debug scope(exit) writeln("gotten.");
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

struct Cluster {
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

	@property const const(ubyte)[] filename() { return data[0..8]; }
	@property ubyte[] filename(ubyte[] fn) { return data[0..8] = fn; }
	@property const const(ubyte)[] extension() { return data[8..11]; }
	@property ubyte[] extension(ubyte[] ex) { return data[8..11] = ex; }
	@property const ubyte attributes() { return data[11]; }
	@property const ushort reserved() { return data.getWordAt(12); }
	@property const ushort creationTime() { return data.getWordAt(14); }
	@property const ushort creationDate() { return data.getWordAt(16); }
	@property const ushort lastAccessDate() { return data.getWordAt(18); }
	@property const ushort IGNORE_IN_FAT12() { return data.getWordAt(20); }
	@property const ushort lastWirteTime() { return data.getWordAt(22); }
	@property const ushort lastWriteDate() { return data.getWordAt(24); }
	@property const ushort firstLogicalCluster() { return data.getWordAt(26); }
	@property ushort firstLogicalCluster(ushort x) { return data.setWordAt(26, x); }
	@property const uint fileSize() { return data.getDoubleAt(28); } // in bytes
	@property uint fileSize(uint x) { return data.setDoubleAt(28, x); }

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

	void save(ubyte[] dest)
	in {
		assert(dest.length == 32);
	} body {
		data.copy(dest);
	}
}

private ushort getWordAt(const ubyte[] data, size_t index) {
	return cast(ushort)(
		data[index] +
		(data[index + 1] << 8)
	);
}

private uint getDoubleAt(const ubyte[] data, size_t index) {
	return cast(uint)(
		data[index] +
		(data[index + 1] << 8) +
		(data[index + 2] << 16) +
		(data[index + 3] << 24)
	);
}

private ushort setWordAt(ubyte[] data, size_t index, ushort val) {
	data[index] = val & 0xff;
	data[index + 1] = (val >> 8) & 0xff;
	return val;
}

private uint setDoubleAt(ubyte[] data, size_t index, uint val) {
	data[index] = val & 0xff;
	data[index + 1] = (val >> 8) & 0xff;
	data[index + 2] = (val >> 16) & 0xff;
	data[index + 3] = (val >> 24) & 0xff;
	return val;
}
