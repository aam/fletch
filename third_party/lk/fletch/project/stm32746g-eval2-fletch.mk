# Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE.md file.

include project/target/stm32746g-eval2.mk

MODULES += app/fletch app/shell

FLETCH_CONFIGURATION = LKFull
FLETCH_GYP_DEFINES = "LK_PROJECT=stm32746g-eval2-fletch LK_CPU=cortex-m4"

WITH_CPP_SUPPORT=true

# Console serial port is on pins PA9(TX) and PA10(RX)
