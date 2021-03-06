// Copyright (c) 2014, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

import 'dart:async';
import 'dart:fletch';

main() {
  var input = new Channel();
  var port = new Port(input);
  Process.spawn(sleepAndThenSend, port);
}

void sleepAndThenSend(Port port) {
  new Timer(const Duration(milliseconds: 100), () {
    port.send(42);
  });
}
