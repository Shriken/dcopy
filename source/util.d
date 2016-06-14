module util;

T popFront(T)(ref T[] arr) {
	T x = arr[0];
	arr = arr[1..$];
	return x;
}
