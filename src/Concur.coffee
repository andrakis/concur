bin2int = (Bin) -> parseInt(Bin, 2)

Concur = (() ->
	namespace =
		opcodes:
			nop:                  ['00000000']
			decl:                 ['00000001']
			assign:               ['00000010']
			observe:              ['00000100']
			push:                 ['00001000']
			extended: ['00000001', '00000000']
			context:  ['00000010', '00000000']
		types:
			pointer:  ['00000100', '00000000']
			number:   ['00001000', '00000000']
			list:     ['00010000', '00000000']
			hash:     ['00100000', '00000000']
			string:   ['01000000', '00000000']
			opcode:   ['10000000', '00000000']
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
		register_syscall: (num, callback) ->
			namespace.syscalls[num] = callback

	# Convert opcodes and types to integers
	for type, i in ['opcodes', 'types']
		for code of namespace[type]
			v = namespace[type][code]
			v = v.join('')
			namespace[type][code] = bin2int(v)
	
	class KeyValueStore
		constructor: (initial) ->
			@data = initial || {}

		isset: (key) -> key of @data
		get: (key) -> @data[key]
		set: (key, value) ->
			@data[key] = value
			@get key
	namespace.KeyValueStore = KeyValueStore

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

	namespace.MakePointer = (MemPos, Process) ->
		new ConcurValue 'pointer', Process, {pointer: MemPos}

	class ConcurStack
		constructor: (parent) ->
			@parent = parent || null
			@pstack = []
			@data = new namespace.KeyValueStore
			@registers = {}
			for register of namespace.registers
				@registers[register] = 0

		get: (name) ->
			return @registers[name] if name of @registers
			return @data.get(name) if @data.isset(name)
			return @parent.get(name) if @parent
			# No match, what to do ...
			throw "not set: " + name

		isset: (name) ->
			return true if name of @registers
			return true if @data.isset(name)
			return true if @parent and @parent.isset(name)
			false

		whereset: (name) ->
			return "register" if name of @registers
			return "data" if @data.isset(name)
			return "parent" if @parent and @parent.isset(name)
			undefined

		set: (name, value) ->
			where = @whereset(name)
			switch where
				when "register" then @registers[name] = value
				# undefined means that it's not set anywhere
				when "data", undefined then @data.set(name, value)
				when "parent" then @parent.set(name, value)
				else throw "don't know how to interpret whereset of: " + where
	
	namespace.ConcurStack = ConcurStack

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

		allocate: (value) ->
			free = @memory_unused_indices.pop()
			if free? then return free
			id = @memory_id_counter++
			@write value, id
			id

		allocate_range: (size, value) ->
			start = @memory_id_counter++
			while size-- > 0
				@write value, start + size
				@memory_id_counter++
			start

		free: (id) ->
			@write 0, id
			@memory_unused_indices.push id
			return

		free_range: (start, size) ->
			while size-- > 0
				@free start + size
			return

		read: (id) -> @memory.get(id)
		write: (value, id) -> @memory.set(id, value)

		stack: () -> @stack_pos
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

		read_observe: (opcode, Process, Stack) ->
			type = opcode ^ namespace.opcodes.observe
			instance = @decl_instance Process, type
			value = @read_type type, Process, Stack
			instance.set namespace.interface.value, value
			pos = Process.allocate instance
			namespace.MakePointer pos, Process

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

		read_string: (Process, Stack) ->
			s = ""
			while r = @readinc_cp(Process, Stack)
				c = switch typeof r
				    when 'string' then r
				    when 'number' then String.fromCharCode(r)
				    else throw 'unknown character in string'
				s += c
			s

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

		execute: (Process) ->
			Stack = Process.read_stack()
			opcode = @readinc_cp Process, Stack

			context = Stack

			# Is this a context opcode?
			if opcode & namespace.opcodes.context
				# Read and update the context
				type = opcode ^ namespace.opcodes.context
				context = switch type
					when namespace.types.string
						name = @read_string Process, Stack
						pos = Stack.get name
						Process.read pos
					else throw "context type not supported"
				# Read next opcode
				opcode = @readinc_cp Process, Stack

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
			0
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