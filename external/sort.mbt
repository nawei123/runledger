///|
priv struct Head {
  record : @ledger.Record
  slot : Int32
}

///|
fn heap_push(heap : Array[Head], value : Head, by_line : Bool) -> Unit {
  heap.push(value)
  let mut i = heap.length() - 1
  while i > 0 {
    let parent = (i - 1) / 2
    if compare_record(heap[parent].record, value.record, by_line) <= 0 {
      break
    }
    heap[i] = heap[parent]
    i = parent
  }
  heap[i] = value
}

///|
fn heap_pop(heap : Array[Head], by_line : Bool) -> Head? {
  if heap.is_empty() {
    return None
  }
  let result = heap[0]
  let last = heap.pop().unwrap()
  if !heap.is_empty() {
    let mut i = 0
    while i * 2 + 1 < heap.length() {
      let mut child = i * 2 + 1
      if child + 1 < heap.length() &&
        compare_record(heap[child + 1].record, heap[child].record, by_line) < 0 {
        child += 1
      }
      if compare_record(last.record, heap[child].record, by_line) <= 0 {
        break
      }
      heap[i] = heap[child]
      i = child
    }
    heap[i] = last
  }
  Some(result)
}

///|
fn write_run(
  rows : Array[@ledger.Record],
  path : String,
  directory : String,
  by_line : Bool,
) -> Unit raise {
  rows.sort_by(fn(a, b) { compare_record(a, b, by_line) })
  let writer = @disk.open(path + ".tmp", write=true)
  defer writer.close()
  for record in rows {
    writer.write_line(record_text(record))
  }
  writer.sync()
  writer.close()
  seal(path, directory)
}

///|
fn close_all(readers : Array[@disk.File]) -> Unit {
  for reader in readers {
    reader.close()
  }
}

///|
fn merge_group(
  directory : String,
  prefix : String,
  generation : Int32,
  start : Int32,
  end : Int32,
  output : Int32,
  options : Options,
  by_line : Bool,
) -> Unit raise {
  let readers : Array[@disk.File] = []
  defer close_all(readers)
  let heap : Array[Head] = []
  for i = start; i < end; i = i + 1 {
    let path = run_path(directory, prefix, generation, i)
    verify(path)
    let reader = @disk.open(path)
    readers.push(reader)
    if next_record(reader, options.max_line_bytes + 1024) is Some(record) {
      heap_push(heap, { record, slot: readers.length() - 1, }, by_line)
    }
  }
  let path = run_path(directory, prefix, generation + 1, output)
  let writer = @disk.open(path + ".tmp", write=true)
  defer writer.close()
  while heap_pop(heap, by_line) is Some(head) {
    writer.write_line(record_text(head.record))
    if next_record(readers[head.slot], options.max_line_bytes + 1024)
      is Some(record) {
      heap_push(heap, { record, slot: head.slot, }, by_line)
    }
  }
  writer.sync()
  writer.close()
  seal(path, directory)
}

///|
fn merge_all(
  state : State,
  control : Control,
  options : Options,
  prefix : String,
  by_line : Bool,
) -> Unit raise {
  while state.runs > 1 {
    if state.generation >= 64 {
      raise EngineError("too many external merge generations")
    }
    let groups = (state.runs - 1) / options.fan_in + 1
    if state.next_group > groups {
      raise EngineError("invalid merge checkpoint")
    }
    // A process may stop after committing a replacement but before deleting inputs.
    if state.next_group > 0 {
      let start = (state.next_group - 1) * options.fan_in
      let end = Int32::min(state.next_group * options.fan_in, state.runs)
      for i = start; i < end; i = i + 1 {
        remove_run(run_path(control.directory, prefix, state.generation, i))
      }
    }
    while state.next_group < groups {
      let group = state.next_group
      let start = group * options.fan_in
      let end = Int32::min(start + options.fan_in, state.runs)
      merge_group(
        control.directory,
        prefix,
        state.generation,
        start,
        end,
        group,
        options,
        by_line,
      )
      state.next_group += 1
      control.save(state)
      // Input runs are deleted only after their replacement and checkpoint commit.
      for i = start; i < end; i = i + 1 {
        remove_run(run_path(control.directory, prefix, state.generation, i))
      }
    }
    state.generation += 1
    state.runs = groups
    state.next_group = 0
    control.save(state)
  }
  if by_line {
    state.order_generation = state.generation
    state.phase = 4
  } else {
    state.identity_generation = state.generation
    state.phase = 2
  }
  control.save(state)
}

///|
priv struct OrderChunks {
  directory : String
  options : Options
  rows : Array[@ledger.Record]
  mut bytes : Int32
  mut runs : Int32
}

///|
fn OrderChunks::flush(self : OrderChunks) -> Unit raise {
  if self.runs >= 2147483646 {
    raise EngineError("too many chunk files")
  }
  write_run(
    self.rows,
    run_path(self.directory, "order", 0, self.runs),
    self.directory,
    true,
  )
  self.runs += 1
  self.rows.clear()
  self.bytes = 0
}

///|
fn OrderChunks::push(self : OrderChunks, record : @ledger.Record) -> Unit raise {
  let size = @utf8.encode(record_text(record)).length()
  if !self.rows.is_empty() &&
    (
      self.bytes > self.options.batch_bytes - size ||
      self.rows.length() >= self.options.batch_rows
    ) {
    self.flush()
  }
  self.rows.push(record)
  self.bytes += size
}
