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

	this(string fn, Image image) {
		this.image = image;

		fn = formatFilename(fn);
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

		auto last = getLastCluster();
		auto size = config.fileSize;
		// if size % bytesPerSector is 0, then the last cluster is full
		auto bps = image.config.bytesPerSector;
		auto bytesInLast = size % bps;
		if (size == 0 || bytesInLast != 0) {
			auto bytesToPut = min(bps - bytesInLast, data.length);
			copy(
				data[0 .. bytesToPut],
				last.data[bytesInLast .. bytesInLast + bytesToPut]
			);
			data = data[bytesToPut .. $];
			config.fileSize = cast(uint)(config.fileSize + bytesToPut);
		}

		if (data.length > 0) {
			last.value = image.getFreeCluster();
			write(data, last.value);
			config.fileSize = cast(uint)(config.fileSize + data.length);
		}
		last.save();

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
		debug writeln("written.");
	}

	private Cluster getLastCluster() {
		debug writeln("getting last cluster...");
		debug scope (exit) writeln("gotten.");
		if (config.firstLogicalCluster.isFree) {
			config.firstLogicalCluster = image.getFreeCluster();
			auto cluster = Cluster(config.firstLogicalCluster, image);
			cluster.value = 0xfff;
		}

		auto cid = config.firstLogicalCluster;
		while (true) {
			auto cluster = Cluster(cid, image);
			if (cluster.value.isFree) {
				cluster.value = 0xfff;
			}
			if (cluster.value.isLast) {
				return cluster;
			}
			cid = cluster.value;
		}
	}

	private void clearChain(ClusterId start) {
		auto cluster = Cluster(start, image);
		if (!cluster.value.isFree) {
			clearChain(cluster.value);
			cluster.value = 0;
		}
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
				if (file.isFree) {
					if (file.restAreFree) {
						debug writeln("not found.");
						return false;
					}
					continue;
				} else if (
					file.filename == fn[0 .. 8]
					&& file.extension == fn [9 .. 12]
				) {
					config = file;
					entryNum = cast(ushort)(
						sectorId * entriesPerSector + entryIndex
					);
					debug writeln("found.");
					return true;
				}
			}
		}
		debug writeln("not found.");
		return false;
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
						entryIndex + (sectorId - ROOT_DIR_START_SECTOR) * entriesPerSector
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
		debug scope(exit) writeln("gotten.");
		foreach (clusterNum; MIN_CLUSTER_ID .. MAX_CLUSTER_ID) {
			auto value = readFatValue(clusterNum);
			if (value.isFree) {
				return clusterNum;
			}
		}
		throw new Exception("no free clusters");
	}

	ClusterId readFatValue(ClusterId clusterNum)
	out(val) {
		assert(val <= 0xfff);
	} body {
		// locate the value
		auto valueStart = (clusterNum * 3) / 2; // byte offset
		auto startingSector = 1 + valueStart / 512;
		auto indexInSector = valueStart % 512;

		// get first and second bytes
		auto bytes = readSector(cast(ushort)startingSector) ~
			readSector(cast(ushort)(startingSector + 1));
		auto word = bytes.getWordAt(indexInSector);

		auto odd = clusterNum % 2 == 1;
		if (odd) {
			return word >> 4;
		} else {
			return word & 0xfff;
		}
	}

	void writeFatValue(ClusterId id, ClusterId value)
	in {
		assert(value <= 0xfff);
	} body {
		// locate the value
		auto valueStart = (id * 3) / 2; // byte offset
		auto startingSector = cast(ushort)(1 + valueStart / 512);
		auto indexInSector = valueStart % 512;

		auto bytes = readSector(startingSector) ~
			readSector(cast(ushort)(startingSector + 1));
		auto word = bytes.getWordAt(indexInSector);
		auto odd = id % 2 == 1;
		if (odd) {
			word = cast(ushort)(value << 4) | (word & 0x000f);
		} else {
			word = value | (word & 0xf000);
		}
		bytes.setWordAt(indexInSector, word);

		// store
		writeSector(startingSector, bytes[0 .. 512]);
		if (indexInSector == 511) {
			writeSector(cast(ushort)(startingSector + 1), bytes[512 .. $]);
		}
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
		this.data = image.readSector(dataSector);
	}

	~this() {
		save();
	}

	void save() {
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
