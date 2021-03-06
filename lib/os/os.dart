// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library dart.fletch.os;

import 'dart:fletch._system' as fletch;
import 'dart:fletch';
import 'dart:fletch.ffi';

part 'native_process.dart';
part 'event_handler.dart';

final ForeignFunction _nanosleep = ForeignLibrary.main.lookup("nanosleep");

class _Timespec extends Struct {
  _Timespec() : super(2);
  int get tv_sec => getField(0);
  int get tv_nsec => getField(1);
  void set tv_sec(int value) => setField(0, value);
  void set tv_nsec(int value) => setField(1, value);
}

// Sleep is still here and not in package:os, as it is used in async_patch.dart.
void sleep(int milliseconds) {
  _Timespec timespec = new _Timespec();
  timespec.tv_sec = milliseconds ~/ 1000;
  timespec.tv_nsec = (milliseconds % 1000) * 1000000;
  int result;
  try {
    result = _nanosleep.icall$2Retry(timespec, timespec);
  } finally {
    timespec.free();
  }
  if (result != 0) throw "Failed to call 'nanosleep': ${Foreign.errno}";
}
