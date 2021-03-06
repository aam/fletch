// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "src/vm/message_mailbox.h"
#include "src/vm/process.h"

namespace fletch {

ExitReference::ExitReference(Process* exiting_process, Object* message)
    : mutable_heap_(NULL, reinterpret_cast<WeakPointer*>(NULL)),
      store_buffer_(true),
      message_(message) {
  mutable_heap_.MergeInOtherHeap(exiting_process->heap());
  store_buffer_.Prepend(exiting_process->store_buffer());
}

Message::~Message() {
  port_->DecrementRef();
  if (kind() == EXIT) {
    ExitReference* ref = reinterpret_cast<ExitReference*>(value());
    delete ref;
  } else if (kind() == PROCESS_DEATH_SIGNAL) {
    Signal* signal = reinterpret_cast<Signal*>(value());
    Signal::DecrementRef(signal);
  }
}

Message* Message::NewImmutableMessage(Port* port, Object* message) {
  if (!message->IsHeapObject()) {
    uint64 address = reinterpret_cast<uint64>(message);
    return new Message(port, address, 0, Message::IMMEDIATE);
  } else if (message->IsImmutable()) {
    uint64 address = reinterpret_cast<uint64>(message);
    return new Message(port, address, 0, Message::IMMUTABLE_OBJECT);
  }
  UNREACHABLE();
  return NULL;
}

void Message::MergeChildHeaps(Process* destination_process) {
  ASSERT(kind() == Message::EXIT);
  ExitReference* ref = reinterpret_cast<ExitReference*>(value());
  destination_process->heap()->MergeInOtherHeap(ref->mutable_heap());
  destination_process->store_buffer()->Prepend(ref->store_buffer());
}

void MessageMailbox::Enqueue(Port* port, Object* message) {
  EnqueueEntry(Message::NewImmutableMessage(port, message));
}

void MessageMailbox::EnqueueLargeInteger(Port* port, int64 value) {
  EnqueueEntry(new Message(port, value, 0, Message::LARGE_INTEGER));
}

void MessageMailbox::EnqueueForeign(Port* port, void* foreign, int size,
                                    bool finalized) {
  Message::Kind kind =
      finalized ? Message::FOREIGN_FINALIZED : Message::FOREIGN;
  uint64 address = reinterpret_cast<uint64>(foreign);
  Message* entry = new Message(port, address, size, kind);
  EnqueueEntry(entry);
}

#ifdef FLETCH_ENABLE_MULTIPLE_PROCESS_HEAPS

void MessageMailbox::EnqueueExit(Process* sender, Port* port, Object* message) {
  // TODO(kasperl): Optimize this to avoid merging heaps if copying is cheaper.
  uint64 address = reinterpret_cast<uint64>(new ExitReference(sender, message));
  Message* entry = new Message(port, address, 0, Message::EXIT);
  EnqueueEntry(entry);
}

#else  // #ifdef FLETCH_ENABLE_MULTIPLE_PROCESS_HEAPS

void MessageMailbox::EnqueueExit(Process* sender, Port* port, Object* message) {
  uint64 address = reinterpret_cast<uint64>(message);
  Message* entry = new Message(port, address, 0, Message::IMMUTABLE_OBJECT);
  EnqueueEntry(entry);
}

#endif  // #ifdef FLETCH_ENABLE_MULTIPLE_PROCESS_HEAPS

void MessageMailbox::MergeAllChildHeaps(Process* destination_process) {
  MergeAllChildHeapsFromQueue(current_message_, destination_process);
  MergeAllChildHeapsFromQueue(last_message_, destination_process);
}

void MessageMailbox::MergeAllChildHeapsFromQueue(Message* queue,
                                                 Process* destination_process) {
  for (Message* current = queue; current != NULL; current = current->next()) {
    if (current->kind() == Message::EXIT) {
      current->MergeChildHeaps(destination_process);
    }
  }
}

}  // namespace fletch
