// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#if defined(FLETCH_TARGET_ARM)

#include "src/vm/assembler.h"

#include <stdio.h>
#include <stdarg.h>

namespace fletch {

void Assembler::b(Label* label) {
  if (label->IsUnused()) label->LinkTo(NewLabelPosition());
  printf("\tb .L%d\n", label->position());
}

void Assembler::Align(int alignment) {
  printf("\t.align %d\n", alignment);
}

void Assembler::Bind(Label* label) {
  if (label->IsUnused()) {
    label->BindTo(NewLabelPosition());
  } else {
    label->BindTo(label->position());
  }
  printf(".L%d:\n", label->position());
}

static const char* ToString(Register reg) {
  static const char* kRegisterNames[] = {
    "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8",
    "r9", "r10", "r11", "ip", "sp", "lr", "pc"
  };
  ASSERT(reg >= R0 && reg <= R15);
  return kRegisterNames[reg];
}

static void PrintRegisterList(RegisterList regs) {
  bool first = true;
  for (int r = 0; r < 16; r++) {
    if ((regs & (1 << r)) != 0) {
      if (first) {
        printf("%s", ToString(static_cast<Register>(r)));
        first = false;
      } else {
        printf(", %s", ToString(static_cast<Register>(r)));
      }
    }
  }
}

void Assembler::Print(const char* format, ...) {
  printf("\t");
  va_list arguments;
  va_start(arguments, format);
  while (*format != '\0') {
    if (*format == '%') {
      format++;
      switch (*format) {
        case '%': {
          putchar('%');
          break;
        }

        case 'a': {
          const Address* address = va_arg(arguments, const Address*);
          PrintAddress(address);
          break;
        }

        case 'r': {
          Register reg = static_cast<Register>(va_arg(arguments, int));
          printf("%s", ToString(reg));
          break;
        }

        case 'R': {
          RegisterList regs =
              static_cast<RegisterList>(va_arg(arguments, int32_t));
          PrintRegisterList(regs);
          break;
        }

        case 'i': {
          const Immediate* immediate = va_arg(arguments, const Immediate*);
          printf("#%d", immediate->value());
          break;
        }

        case 'o': {
          const Operand* operand = va_arg(arguments, const Operand*);
          PrintOperand(operand);
          break;
        }

        case 's': {
          const char* label = va_arg(arguments, const char*);
          printf("%s", label);
          break;
        }

        default: {
          UNREACHABLE();
          break;
        }
      }
    } else {
      putchar(*format);
    }
    format++;
  }
  va_end(arguments);
  putchar('\n');
}

void Assembler::PrintAddress(const Address* address) {
  if (address->kind() == Address::IMMEDIATE) {
    printf("[%s, #%d]", ToString(address->base()), address->offset());
  } else {
    ASSERT(address->kind() == Address::OPERAND);
    printf("[%s, ", ToString(address->base()));
    PrintOperand(address->operand());
    printf("]");
  }
}

void Assembler::PrintOperand(const Operand* operand) {
  printf("%s, lsl #%d", ToString(operand->reg()), operand->scale());
}

int Assembler::NewLabelPosition() {
  static int labels = 0;
  return labels++;
}

}  // namespace fletch

#endif  // defined(FLETCH_TARGET_ARM)
