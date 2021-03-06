// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

// FletchDebuggerCommands=b breakHere,r,f 1,p *a,p *i,c

class S0 {
  var str = 'spaß';
}

class S1 extends S0 {
  var i = 42;
  var i2 = 1 << 33;
}

class S2 extends S1 {
  var n;
  var d = 42.42;
}

class S3 extends S2 {
  var shadowMe = 0;
}

class A extends S3 {
  var shadowMe = 42;
  var t = true;
  var f = false;
}

breakHere() { }

main() {
  var a = new A();
  var i = 42;
  breakHere();
}
