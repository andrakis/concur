Concur Virtual Machine
======================

Concur is an object-based minimalist virtual machine.
It is designed with concurrency, portability, and lightweightedness(?) in mind.

Concurrency:
------------

  * Concur uses a lightweight process model, whereby a single virtual machine
    instance can run many lightweight Concur virtual processes.

  * Message passing allows communication between Concur lightweight processes.

  * Concur allows for transport of messages between processes. These are copied,
    not referenced, so that no memory sharing is needed.

Portability:
------------

  * The virtual machine (VM) is designed with a minimalist approach. The VM
    aims for a very simple implementation, with a base language that allows for
    implementation of many different runtime languages.

  * Most of the virtual machine is designed around a key/value store (or hash),
    or possibly better described as the "object model". This can be easily
    expressed in many languages, allowing for greater portability.

Lightweightedness:
------------------

Full disclosure: Ok, so that's not really a word. But it's an aim.

  * The virtual machine is designed around a small set of features in which
    to implement a more fuller language. The most basic yet efficient virtual
    machine is the goal.

  * The object model is the main design of the virtual machine. This allows
    for a simple implementation to be extended quite significantly using only
    the language constructs provided by an object model.

General background
------------------

Most of the design of this virtual machine has come about based on my
experiments with a single-op virtual machine and trying to design a macro
language to make it easier to program.

The machine concept was conceived in the late 90's, but it wasn't until much
later that I was able to turn that concept into reality.

Cumulative used a simple register model to accomplish tasks such as addition,
subtraction, and comparison. This allowed the virtual machine to operate using
a single operation:
  add *src, increment, destination

  Read from memory location src, add integer "increment" to it, and store in
  memory location "destination"

Through judicious use of various registers, you can implement a Turing-complete
language through this 1 instruction.

After the Cumulative project, I worked on a single character virtual machine called
Club (unreleased) which was designed with (Code Golf)[http://codegolf.stackexchange.com/] in mind.
The aim was the simplest virtual machine that could tackle the challenges posted
on Code Golf.

A single character VM is a fairly different challenge from a single op VM.
This VM worked on using the "last value" for executing the next operation.
This design can be seen in Concur's use of observing data and then using that
for the next instruction.

More Cumulative background
--------------------------

The (sample page)[http://htmlpreview.github.io/?https://github.com/andrakis/gleam/blob/master/cumulative/cumulative.html] has the full Cumulative interpreter
in Javascript. It is preloaded with a simple program to call a function, get a
return value, and then jump to an endless loop.

The instructions for Concur are based around a macro language I started to
design for Cumulative. They operate around the idea of observing data so that
the registers of interest were loaded with (or cleared of) the data needed to
perform computations.
As an example, this is how 2 integers were read and added:
  add 0, 0, $ac         ; Clear accumulator
  add $val1, 0, $val1   ; "Observe" value 1 to add it to the accumulator.
                        ; The value is read from, has nothing added to it,
                        ; and is then stored in the same location it came from.
                        ; This effectively just reads the value.
  add $val2, 0, $val2   ; Same as above
  add $ac, 0, $dest     ; Read from accumulator, store to destination.

Other registers allow for jumping (code pointer register), comparison checks
(> 0 register, == 0 register, < 0 register) which can be added to the code
pointer register to jump based on comparisons.

