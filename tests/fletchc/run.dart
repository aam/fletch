// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library fletchc.test.run;

import 'dart:async';

import 'dart:io';

import 'dart:io' as io;

import 'package:fletchc/src/hub/session_manager.dart';

import 'package:fletchc/src/worker/developer.dart';

import 'package:fletchc/src/worker/developer.dart' as developer;

import 'package:fletchc/src/verbs/infrastructure.dart' show fileUri;

import 'package:fletchc/src/device_type.dart' show
    DeviceType,
    parseDeviceType;

const String userVmAddress = const String.fromEnvironment("attachToVm");

const String exportTo = const String.fromEnvironment("snapshot");

const String userPackages = const String.fromEnvironment("packages");

const String userAgentAddress = const String.fromEnvironment("agent");

const String fletchSettingsFile =
    const String.fromEnvironment("test.fletch_settings_file_name");

/// Enables printing of Compiler/VM protocol commands after each compilation.
const bool printCommands = const bool.fromEnvironment("printCommands");

/// Enables pretty printing the Fletch system (the compilation result) after
/// each compilation.
const bool printSystem = const bool.fromEnvironment("printSystem");

class FletchRunner {
  Future<Null> attach(SessionState state) async {
    if (userVmAddress == null) {
      await startAndAttachDirectly(state, Uri.base);
    } else {
      Address address = parseAddress(userVmAddress);
      await attachToVm(address.host, address.port, state);
    }
  }

  Future<Settings> computeSettings() async {
    if (fletchSettingsFile != null) {
      return await readSettings(fileUri(fletchSettingsFile, Uri.base));
    }
    Address agentAddress =
        userAgentAddress == null ? null : parseAddress(userAgentAddress);
    return new Settings(
        fileUri(userPackages == null ? ".packages" : userPackages, Uri.base),
        ["--verbose"],
        <String, String>{
          "foo": "1",
          "bar": "baz",
        },
        agentAddress,
        DeviceType.mobile,
        IncrementalMode.production);
  }

  Future<Null> run(List<String> arguments) async {
    Settings settings = await computeSettings();
    SessionState state = createSessionState("test", settings);
    for (String script in arguments) {
      print("Compiling $script");
      await compile(fileUri(script, Uri.base), state, Uri.base);
      if (state.compilationResults.isNotEmpty) {
        // Always generate the debug string to ensure test coverage.
        String debugString =
            state.compilationResults.last.system.toDebugString(Uri.base);
        if (printSystem) {
          // But only print the debug string if requested.
          print(debugString);
        }
        if (printCommands) {
          print("Compiled $script");
          for (var delta in state.compilationResults) {
            print("\nDelta:");
            for (var cmd in delta.commands) {
              print(cmd);
            }
          }
        }
      }
      await attach(state);
      state.stdoutSink.attachCommandSender(stdout.add);
      state.stderrSink.attachCommandSender(stderr.add);

      if (exportTo != null) {
        await developer.export(state, fileUri(exportTo, Uri.base));
      } else {
        await developer.run(state);
      }
      if (state.fletchVm != null) {
        int exitCode = await state.fletchVm.exitCode;
        print("$script: Fletch VM exit code: $exitCode");
        if (exitCode != 0) {
          io.exitCode = exitCode;
          break;
        }
      }
    }
    print(state.getLog());
  }
}

main(List<String> arguments) async {
  await new FletchRunner().run(arguments);
}

Future<Null> test() => main(<String>['tests/language/application_test.dart']);

// TODO(ahe): Move this method into FletchRunner and use computeSettings.
Future<Null> export(
    String script, String snapshot, {bool binaryProgramInfo: false}) async {
  Settings settings;
  if (fletchSettingsFile == null) {
    settings = new Settings(
        fileUri(".packages", Uri.base),
        <String>[],
        <String, String>{},
        null,
        null,
        IncrementalMode.none);
  } else {
    settings = await readSettings(fileUri(fletchSettingsFile, Uri.base));
  }
  SessionState state = createSessionState("test", settings);
  await compile(fileUri(script, Uri.base), state, Uri.base);
  await startAndAttachDirectly(state, Uri.base);
  state.stdoutSink.attachCommandSender(stdout.add);
  state.stderrSink.attachCommandSender(stderr.add);
  await developer.export(
      state, fileUri(snapshot, Uri.base), binaryProgramInfo: binaryProgramInfo);
}
