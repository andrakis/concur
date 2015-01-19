bin2int = (Bin) -> parseInt(Bin, 2)

Concur = (() ->
	namespace =
		opcodes:
			nop:                  ['00000000']   # No operation, do nothing
			decl:                 ['00000001']   # Declare a Stack variable
			assign:               ['00000010']   # Assign last value to a stack variable
			observe:              ['00000100']   # Observe a value (can be assigned)
			push:                 ['00001000']   # Push the given Stack variable onto the parameter stack
			extended: ['00000001', '00000000']
			context:  ['00000010', '00000000']   # Instead of using the Stack, use the given stack variable as context
		types:
			pointer:  ['00000100', '00000000']
			number:   ['00001000', '00000000']
			list:     ['00010000', '00000000']
			hash:     ['00100000', '00000000']
			string:   ['01000000', '00000000']
			opcode:   ['10000000', '00000000']
			literal:  ['10000000', '00000000', '00000000']  # Literal, ie no lookup
		registers:
			sp: 'stack pointer'
			cp: 'code pointer'
			r0: 'general purpose register 0'
			r1: 'general purpose register 1'
			r2: 'general purpose register 2'
			r3: 'general purpose register 3'
			r4: 'general purpose register 4'
		# Standard Concur object model interface
		interface:
			value: '__value'
			read:  '__read'
			write: '__write'
			type:  '__type'
			process:    '__process'
			process_id: '__process_id'
			lastValue: '$last'
		syscalls: {}
		syscalls_by_num: {}
		register_syscall: (name, num, callback) ->
			namespace.syscalls_by_num[num] = callback
			namespace.syscalls[name] = num

	# Convert opcodes and types to integers
	for type, i in ['opcodes', 'types']
		for code of namespace[type]
			v = namespace[type][code]
			v = v.join('')
			namespace[type][code] = bin2int(v)
	
	# The base class, Concur extends this for all native language constructs
	class KeyValueStore
		constructor: (initial) ->
			@data = initial || {}

		isset: (key) -> key of @data
		get: (key) -> @data[key]
		set: (key, value) ->
			@data[key] = value
			@get key
	namespace.KeyValueStore = KeyValueStore

	# The base native Concur class. This handles some niceties that a Concur
	# process will need, such as the process reference and type of the object.
	# This class implements the basic interface for a Concur object.
	class ConcurValue extends KeyValueStore
		constructor: (type, Process, value) ->
			@type = type
			@set namespace.interface.type, type
			@set namespace.interface.process, Process
			if value
				instance = @
				if value.pointer?
					# TODO: Not tested or used yet
					instance.set namespace.interface.value, value.pointer
					instance.set namespace.interface.read, () ->
						Process = instance.get namespace.interface.process
						pos = instance.get namespace.interface.value
						Process.read pos
				else
					instance.set namespace.interface.value, value
					instance.set namespace.interface.read, () -> instance.get namespace.interface.value
				instance.set namespace.interface.write, (v) -> instance.set namespace.interface.value, v
			return
	namespace.ConcurValue = ConcurValue

	# Shortcut for creating a pointer to a memory position on a process
	namespace.MakePointer = (MemPos, Process) ->
		new ConcurValue 'pointer', Process, {pointer: MemPos}

	# The Concur Stack.
	# Every time a function call occurs, a new stack is created as a child of
	# the current stack.
	# The child may reference the parent stack to grab symbols from it.
	# A child's stack symbol overrides a reference further up in the parental
	# heirarchy.
	class ConcurStack
		constructor: (parent) ->
			@parent = parent || null
			# Parameter stack
			@pstack = []
			# Keys are strings, values are references to data
			@data = new namespace.KeyValueStore
			# Create registers
			@registers = {}
			for register of namespace.registers
				@registers[register] = 0

		# Get the value of the key "name". Throws an exception if not set.
		# Use isset to check if the key exists.
		get: (name) ->
			return @registers[name] if name of @registers
			return @data.get(name) if @data.isset(name)
			return @parent.get(name) if @parent
			# No match, what to do ...
			throw "not set: " + name

		# Check if the key "name" is set.
		isset: (name) ->
			return true if name of @registers
			return true if @data.isset(name)
			return true if @parent and @parent.isset(name)
			false

		# Check where the key "name" is set.
		whereset: (name) ->
			return "register" if name of @registers
			return "data" if @data.isset(name)
			return "parent" if @parent and @parent.isset(name)
			undefined

		# Set a key of "name" to "value".
		# This will reference UP the stack, ie it first checks where the key
		# "name" is set, and then sets it there.
		# THIS ALTERS THE VALUE OF THE KEY ON PARENT STACKS.
		# It cannot be used to create a new local variable named "key" if one
		# already exists in the parent. To perform that operation, use set_shallow.
		set: (name, value) ->
			where = @whereset name
			switch where
				when "register" then @registers[name] = value
				# undefined means that it's not set anywhere
				when "data", undefined then @data.set name, value
				when "parent" then @parent.set name, value
				else throw "don't know how to interpret whereset of: " + where

		# A "shallow" version of set that does not look for where "name" is
		# defined. This lets you create new local keys.
		set_shallow: (name, value) ->
			if name of @registers
				@registers[name] = value
			else
				@data.set name, value

		# Push a reference onto the stack.
		# It should always be a reference, not a literal.
		push: (ref) ->
			@pstack.push ref
			ref

		# Pop a reference off the stack.
		pop: () ->
			@pstack.pop()

		pstack_length: () ->
			@pstack.length
	
	namespace.ConcurStack = ConcurStack

	# The Concur process.
	# The process is where all data is stored, including the code to execute.
	# New data is allocated in the memory of the process, and a reference is
	# used to reference memory locations.
	class ConcurProcess
		@process_id_counter = 0

		constructor: () ->
			@memory = new namespace.KeyValueStore
			@memory_id_counter = 0
			@memory_unused_indices = []

			stack = new namespace.ConcurStack
			process_id = ConcurProcess.process_id_counter++
			stack.set namespace.interface.process_id, process_id
			@stack_pos = @base_stack_pos = @allocate stack
			@stack_ref = namespace.MakePointer @stack_pos, @

		# Allocate a single memory position, and set it to "value".
		# Value may be anything (not type restricted.)
		allocate: (value) ->
			id = @memory_unused_indices.pop()
			if !id
				# Didn't get an indice, grab the next position and increment
				id = @memory_id_counter++
			@write value, id
			id

		# Allocate a range of size, and set to value.
		# If value is an array, each value will be shifted and written.
		# Otherwise, the value will be written to each memory cell.
		allocate_range: (size, value) ->
			start = @memory_id_counter++
			
			while size-- > 0
				if typeof value == typeof [] && value.length
					@write value.shift(), start + size
				else
					@write value, start + size
				@memory_id_counter++
			start

		# Frees the given memory location.
		free: (id) ->
			@write 0, id
			@memory_unused_indices.push id
			return

		# Frees the given memory range.
		free_range: (start, size) ->
			while size-- > 0
				@free start + size
			return

		# Read the memory cell at "id"
		read: (id) -> @memory.get(id)
		# Write to the memory cell at "id"
		write: (value, id) -> @memory.set(id, value)

		# Get the current stack position in memory
		stack: () -> @stack_pos
		# Read the current stack position from memory
		read_stack: () -> @read @stack()

	namespace.ConcurProcess = ConcurProcess

	class ConcurVEU
		constructor: () ->

		# Read and increment cp
		readinc_cp: (Process, Stack) ->
			cp = Stack.get('cp')
			value = Process.read cp
			Stack.set 'cp', cp + 1
			value

		# Read a decl type and name
		read_decl: (opcode, Process, Stack) ->
			type = opcode ^ namespace.opcodes.decl
			name = @read_string Process, Stack
			[type, name]

		# Read an observation. This will be stored into the $last value for use
		# in subsequent instructions.
		read_observe: (opcode, Process, Stack) ->
			type = opcode ^ namespace.opcodes.observe
			instance = @decl_instance Process, type
			value = @read_type type, Process, Stack
			instance.set namespace.interface.value, value
			pos = Process.allocate instance
			namespace.MakePointer pos, Process
		
		# Read a push instruction.
		# If the type is string, then the code assumes you are referencing a
		# stack variable by that name.
		# TODO: Doesn't let us push anything except currently declared stack
		#       variables. This means that you cannot push literals yet.
		read_push: (opcode, Process, Stack) ->
			type = opcode ^ namespace.opcodes.push
			ref = @read_type type
			ref = switch type
				when namespace.types.string
					name = ref
					throw "symbol " + name + " not found" if !Stack.isset name
					Stack.get name
				else
					throw "Symbol type " + type + " not supported in push: "
			Stack.push ref

		read_pop: (val, opcode, Process, Stack) ->
			type = opcode & namespace.opcodes.pop
			ref = @read_type type
			# TODO: This function only allows storing to registers or stack
			#       variables. You cannot use this within a context op.
			#       (You can, but it will store to the Stack, not the context.)
			switch type
				when namespace.types.string
					name = ref
					Stack.set name, val
				# TODO: Store to memory location?
				else
					throw "Unable to handle pop to non-string destinations"

		# Read the given type from the Process. Increments Stack's cp.
		read_type: (type, Process, Stack) ->
			switch type
				when namespace.types.pointer, namespace.types.number
					@readinc_cp Process, Stack
				when namespace.types.list
					throw "not implemented"
				when namespace.types.hash
					throw "not implemented"
				when namespace.types.string
					@read_string Process, Stack
				when namespace.types.opcode
					throw "not implemented"
				else
					throw "type not known " + type

		# Read a string from the Process. The string should be nul terminated.
		read_string: (Process, Stack) ->
			s = ""
			while r = @readinc_cp(Process, Stack)
				c = switch typeof r
				    when 'string' then r
				    when 'number' then String.fromCharCode(r)
				    else throw 'unknown character in string'
				s += c
			s

		# Declare an instance variable of "type" and allocate it on the given
		# Process.
		decl_instance: (Process, type) ->
			raw = switch
				when type & namespace.types.pointer then pointer: 0
				when type & namespace.types.number then 0
				when type & namespace.types.list then []
				when type & namespace.types.hash then {}
				when type & namespace.types.string then ""
				when type & namespace.types.opcode then opcode: []
				else throw 'unknown type'
			new namespace.ConcurValue type, Process, raw

		# Grab an operation from the Process Stack, and execute it
		execute: (Process) ->
			Stack = Process.read_stack()
			opcode = @readinc_cp Process, Stack

			context = Stack

			# Is this a context opcode?
			if opcode & namespace.opcodes.context
				# Read and update the context
				# Expects type string, the string should be the name of
				# the stack variable.
				type = opcode ^ namespace.opcodes.context
				context = switch type
					when namespace.types.string
						name = @read_string Process, Stack
						pos = Stack.get name
						Process.read pos
					else throw "context type not supported"
				# Read next opcode
				opcode = @readinc_cp Process, Stack

			# Perform the operation
			result = switch
				when opcode == namespace.opcodes.nop
					# Do nothing
					0
				when opcode & namespace.opcodes.decl
					# Declare
					[type, name] = @read_decl opcode, Process, Stack
					instance = @decl_instance Process, type
					pos = Process.allocate instance
					ref = namespace.MakePointer pos, Process
					Stack.set name, ref
					ref
				when opcode & namespace.opcodes.observe
					# Observe
					@read_observe opcode, Process, Stack
				when opcode & namespace.opcodes.assign
					# Assign $last to the given member name
					last = Stack.get namespace.interface.lastValue
					destMemberName = @read_string Process, Stack
					context.set destMemberName, last
				when opcode & namespace.opcodes.push
					# Push a reference to the stack
					@read_push opcode, Process, Stack
				when opcode & namespace.opcodes.pop
					# Pop a reference off the stack
					if Stack.pstack_length() == 0
						throw "GPF: Nothing left in stack to pop"
					val = Stack.pop()
					@read_pop val, opcode, Process, Stack
				else
					# Error
					# TODO: implement local syscall
					throw "unknown opcode"

			Stack.set namespace.interface.lastValue, result
			
	namespace.ConcurVEU = ConcurVEU;

	namespace
)()

class TestSuite
	test: () ->
		# Register a debug syscall
		Concur.register_syscall 'Debug', -1, (Stack) ->
			while v = Stack.pop()
				console.log v

		p = @create_process()
		code = [
			# decl hash:test
			Concur.opcodes.decl | Concur.types.hash,
			't', 'e', 's', 't', 0,
			# observe s:"hello"
			Concur.opcodes.observe | Concur.types.string,
			'h', 'e', 'l', 'l', 'o', 0,
			# context test assign str
			Concur.opcodes.context | Concur.types.string,
			't', 'e', 's', 't', 0,
			Concur.opcodes.assign | Concur.types.string,
			's', 't', 'r', 0,
			# context test push str
			Concur.opcodes.context | Concur.types.string,
			't', 'e', 's', 't', 0,
			Concur.opcodes.push | Concur.types.string,
			's', 't', 'r', 0
			# syscall 0
			Concur.opcodes.syscall | Concur.types.number,
			Concur.syscalls['Debug']
		]
		pos = p.allocate_range code.length, 0
		p.write datum, pos + i for datum, i in code
		# Point cp to code we allocated
		stack = p.read_stack()
		stack.set 'cp', pos

		veu = new Concur.ConcurVEU
		r1 = veu.execute p
		r2 = veu.execute p
		r3 = veu.execute p
		

	create_process: () ->
		p = new Concur.ConcurProcess

test = new TestSuite
window.j = test.test()