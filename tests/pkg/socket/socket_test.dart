// Copyright (c) 2014, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

import 'dart:typed_data';

import 'package:expect/expect.dart';
import 'package:os/os.dart' as os;
import 'package:socket/socket.dart';

void main() {
  testLookup();
  testBindListen();
  testConnect();
  testReadWrite();
  testReadNext();
  testSpawnAccept();
  testLargeChunk();
  testShutdown();
  testFailingBind();
}

void testFailingBind() {
  Expect.throws(() {
    new ServerSocket("128.0.0.1", 12345);
    new ServerSocket("128.0.0.1", 12345);
  }, isSocketException);
}

void testLookup() {
  os.InternetAddress address = os.sys.lookup("127.0.0.1");
  Expect.isTrue(address is os.InternetAddress);
}

void testBindListen() {
  new ServerSocket("127.0.0.1", 0).close();
}

void testConnect() {
  var server = new ServerSocket("127.0.0.1", 0);

  var socket = new Socket.connect("127.0.0.1", server.port);

  var client = server.accept();
  Expect.isNotNull(client);

  client.close();
  socket.close();
  server.close();
}

createBuffer(int length) {
  var list = new Uint8List(length);
  for (int i = 0; i < length; i++) {
    list[i] = i & 0xFF;
  }
  return list.buffer;
}

void validateBuffer(buffer, int length) {
  Expect.equals(length, buffer.lengthInBytes);
  var list = new Uint8List.view(buffer);
  for (int i = 0; i < length; i++) {
    Expect.equals(i & 0xFF, list[i]);
  }
}

const CHUNK_SIZE = 256;
const SMALL_READ_BUFFER = CHUNK_SIZE ~/ 8;


void testReadWrite() {
  var server = new ServerSocket("127.0.0.1", 0);
  var socket = new Socket.connect("127.0.0.1", server.port);
  var client = server.accept();

  socket.write(createBuffer(CHUNK_SIZE));
  validateBuffer(client.read(CHUNK_SIZE), CHUNK_SIZE);

  client.write(createBuffer(CHUNK_SIZE));
  validateBuffer(socket.read(CHUNK_SIZE), CHUNK_SIZE);

  Expect.equals(0, socket.available);
  Expect.equals(0, client.available);

  client.close();
  socket.close();
  server.close();
}

writeTo(bufferFrom, bufferTo, index) {
  var listFrom = bufferFrom.asUint8List();
  var listTo = bufferTo.asUint8List();
  listTo.setRange(index, index + listFrom.length, listFrom);
}

void testReadNext() {
  var server = new ServerSocket("127.0.0.1", 0);
  var socket = new Socket.connect("127.0.0.1", server.port);
  var client = server.accept();

  socket.write(createBuffer(CHUNK_SIZE));
  var combined = new Uint8List(CHUNK_SIZE).buffer;
  int read = 0;
  while (read < CHUNK_SIZE) {
    var back = client.readNext();
    writeTo(back, combined, read);
    read += back.lengthInBytes;
  }
  Expect.equals(read, CHUNK_SIZE);
  Expect.equals(client.available, 0);
  validateBuffer(combined, CHUNK_SIZE);

  socket.write(createBuffer(CHUNK_SIZE));
  read = 0;
  while(read < CHUNK_SIZE) {
    var back = client.readNext(SMALL_READ_BUFFER);
    writeTo(back, combined, read);
    read += back.lengthInBytes;
  }
  Expect.equals(read, CHUNK_SIZE);
  Expect.equals(client.available, 0);
  validateBuffer(combined, CHUNK_SIZE);

  client.close();
  socket.close();
  server.close();
}

void spawnAcceptCallback(Socket client) {
  validateBuffer(client.read(CHUNK_SIZE), CHUNK_SIZE);
  client.write(createBuffer(CHUNK_SIZE));
  Expect.equals(0, client.available);

  client.close();
}

void testSpawnAccept() {
  var server = new ServerSocket("127.0.0.1", 0);
  var socket = new Socket.connect("127.0.0.1", server.port);
  server.spawnAccept(spawnAcceptCallback);

  socket.write(createBuffer(CHUNK_SIZE));
  validateBuffer(socket.read(CHUNK_SIZE), CHUNK_SIZE);
  Expect.equals(0, socket.available);

  socket.close();
  server.close();
}

const LARGE_CHUNK_SIZE = 128 * 1024;

void largeChunkClient(Socket client) {
  validateBuffer(client.read(LARGE_CHUNK_SIZE), LARGE_CHUNK_SIZE);
  client.write(createBuffer(LARGE_CHUNK_SIZE));
  Expect.equals(0, client.available);

  client.close();
}

void testLargeChunk() {
  var server = new ServerSocket("127.0.0.1", 0);
  var socket = new Socket.connect("127.0.0.1", server.port);
  server.spawnAccept(largeChunkClient);

  socket.write(createBuffer(LARGE_CHUNK_SIZE));
  validateBuffer(socket.read(LARGE_CHUNK_SIZE), LARGE_CHUNK_SIZE);

  Expect.equals(0, socket.available);

  socket.close();
  server.close();
}

bool isSocketException(e) => e is SocketException;

void testShutdown() {
  var server = new ServerSocket("127.0.0.1", 0);
  var socket = new Socket.connect("127.0.0.1", server.port);
  var client = server.accept();

  socket.write(createBuffer(CHUNK_SIZE));
  socket.shutdownWrite();

  validateBuffer(client.read(CHUNK_SIZE), CHUNK_SIZE);
  Expect.equals(null, client.read(CHUNK_SIZE));
  client.write(createBuffer(CHUNK_SIZE));
  client.shutdownWrite();

  validateBuffer(socket.read(CHUNK_SIZE), CHUNK_SIZE);
  Expect.equals(null, socket.read(CHUNK_SIZE));

  Expect.throws(() => client.write(createBuffer(CHUNK_SIZE)),
                isSocketException);
  Expect.throws(() => socket.write(createBuffer(CHUNK_SIZE)),
                isSocketException);

  client.close();
  socket.close();
  server.close();
}
