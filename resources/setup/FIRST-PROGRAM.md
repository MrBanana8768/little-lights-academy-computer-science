# Your first Java program — by hand

No IDE. No project wizard. No template. You are going to create a file with your own
hands, type every character of it, compile it, and run it.

This matters. IntelliJ can generate all of this for you in two clicks, and later it
will. But if the first time you see `public static void main(String[] args)` it was
written *for* you, it stays a magic incantation you retype without understanding. Do it
the hard way once and it stops being magic.

**Rule for this exercise: do not copy and paste. Type it.** Your fingers are part of
how you learn this.

---

## 1. Make somewhere to work

```bash
mkdir first-program
```

```bash
cd first-program
```

## 2. Create the file

Use whatever plain editor you like. VS Code was installed for exactly this kind of job:

```bash
code Hello.java
```

If you'd rather stay in the terminal: `notepad Hello.java` on Windows, or `nano
Hello.java` on Linux.

**The filename matters.** Capital `H`, and the extension is `.java`, not `.txt`. You'll
find out why in section 6.

## 3. Type this

```java
public class Hello {
    public static void main(String[] args) {
        System.out.println("Hello, world!");
    }
}
```

Save it.

## 4. Compile it

```bash
javac Hello.java
```

If nothing is printed, it worked. Java's compiler is silent on success — no news is
good news. Look at what appeared:

```bash
ls
```

(`dir` on Windows PowerShell works too.)

There are now **two** files: your `Hello.java` and a new `Hello.class`. The `.java` file
is the source you wrote, for humans. The `.class` file is **bytecode** — instructions
for the Java Virtual Machine. It isn't a Windows or Linux program; it's a program for
the JVM, which is why the same `.class` file runs on both.

Try opening `Hello.class` in your editor. It's gibberish. That's the point — that's what
"compiled" means.

## 5. Run it

```bash
java Hello
```

```
Hello, world!
```

Note carefully: **`java Hello`, not `java Hello.class` and not `java Hello.java`.** You
are naming the *class* you want to run, not a file. Getting this wrong is the single
most common first-day error, and section 7 makes you do it on purpose.

---

## 6. What every word means

Nothing here is decoration. Take it one piece at a time.

```java
public class Hello {
```

**`class`** — Java has nowhere to put code except inside a class. Even a program this
small needs one. A class is a named box for code and data.

**`Hello`** — the class's name. **It must match the filename exactly**, including
capitalisation. `Hello.java` must contain `class Hello`. This is a hard rule for public
classes, not a convention, and the compiler enforces it.

**`public`** — visible from anywhere. The JVM is "anywhere", so it has to be public for
the JVM to start it.

```java
    public static void main(String[] args) {
```

This whole line is a **method** — a named chunk of code you can run. Reading it
backwards is easier than forwards:

**`(String[] args)`** — the *parameters*. `String` means text; `String[]` means "an
array of text"; `args` is just the name we give it. These are the command-line
arguments — the extra words you type after the program name. You'll prove this is real
in section 8.

**`main`** — the name. When you run `java Hello`, the JVM looks inside the `Hello` class
for a method called exactly `main`. Spell it `Main` or `mian` and your program will
compile perfectly and refuse to start.

**`void`** — what the method gives back when it finishes. `void` means *nothing*. Other
methods return a number or a piece of text; `main` returns nothing.

**`static`** — belongs to the *class* itself, not to an individual object made from it.
This one matters: when the JVM starts, no objects exist yet. There is no `Hello` to ask.
`static` is what lets the JVM call `main` without creating anything first.

**`public`** — again, so the JVM can reach it from outside.

```java
        System.out.println("Hello, world!");
```

**`System`** is a built-in class. **`out`** is the standard output stream inside it —
your terminal. **`println`** is a method on that stream: "print this, then a new line."
The `"double quotes"` make it a `String`. The **`;`** ends the statement — Java needs it,
every time.

```java
    }
}
```

Two closing braces: one ends `main`, one ends the class. Every `{` needs its `}`. The
indentation is purely for humans — Java ignores it completely — but write it properly
anyway, because humans have to read your code, including you in three weeks.

---

## 7. Now break it on purpose

This is the most useful part of the exercise. **Everyone's code fails to compile —
constantly, professionally, forever.** The skill isn't avoiding errors, it's reading
them. So let's meet them deliberately, while you already know what the cause is.

Do these one at a time. Make the change, run `javac Hello.java`, read the error, then
put it back.

### 7a. Delete a semicolon

Remove the `;` after `println("Hello, world!")`.

```
Hello.java:3: error: ';' expected
```

Note the **`:3:`** — that's the line number. Compiler errors tell you where. Always read
the line number first, and always fix the *top* error first: one mistake often causes a
cascade of others below it.

### 7b. Rename the class but not the file

Change `class Hello` to `class Greeting`, leave the file called `Hello.java`.

```
Hello.java:1: error: class Greeting is public, should be declared in a file named Greeting.java
```

That's the filename rule from section 6, enforced.

### 7c. Lowercase the `S` in `String`

```
Hello.java:2: error: cannot find symbol
  symbol:   class string
```

**`cannot find symbol` means "you used a name I've never heard of."** Nine times out of
ten it's a typo or wrong capitalisation. Java is case-sensitive everywhere: `String`
and `string` are unrelated words.

### 7d. Misspell `println` as `printn`

```
Hello.java:3: error: cannot find symbol
  symbol:   method printn(String)
```

Same error, different symbol. Note it tells you the *method* it looked for and the
argument type it saw.

### 7e. Delete the word `static`

Compile it:

```bash
javac Hello.java
```

**It compiles.** No error at all. Now run it:

```bash
java Hello
```

```
Error: Main method is not static in class Hello, please define the main method as:
   public static void main(String[] args)
```

This is the important one. There are **two completely different times things can go
wrong**: *compile time*, when `javac` checks your code, and *runtime*, when the JVM
actually executes it. The compiler only checks that your code is legal Java — it has no
idea you intended this class to be a runnable program. Plenty of bugs sail through
compilation and only show up when you run.

### 7f. Run the wrong thing

With the file back to working order:

```bash
java Hello.class
```

```
Error: Could not find or load main class Hello.class
```

`java` takes a **class name**, not a filename. Now you've seen the error, so you'll
recognise it at 2am.

---

## 8. Make `args` do something

`String[] args` isn't decoration — it's how a program receives input from the command
line. Prove it. Change `main` to:

```java
public static void main(String[] args) {
    System.out.println("Hello, " + args[0] + "!");
}
```

Compile, then run it with a word after the class name:

```bash
javac Hello.java
```

```bash
java Hello Ada
```

```
Hello, Ada!
```

That word landed in `args[0]`. Arrays in Java are numbered from **0**, not 1.

Now run it with no word at all:

```bash
java Hello
```

```
Exception in thread "main" java.lang.ArrayIndexOutOfBoundsException: Index 0 out of bounds for length 0
```

Another runtime error — the array was empty, so `args[0]` didn't exist. You just met
your first **exception**. You'll meet a great many more.

---

## 9. A shortcut you've now earned

Since Java 11 you can skip the compile step for a single file:

```bash
java Hello.java
```

That compiles it in memory and runs it, producing no `.class` file. It's handy for quick
experiments.

It's shown to you *last* on purpose. Now you know exactly what it's hiding: it still
compiles, it just throws the bytecode away afterwards. Real projects always compile
properly — and once your program is more than one file, this shortcut stops working.

---

## 10. Commit it

You've written something. Put it in version control — same loop you'll use for every
assignment (see [GIT-QUICKSTART.md](GIT-QUICKSTART.md)):

```bash
git init
```

```bash
git status
```

Look at what it lists. `Hello.class` is a *build artifact* — generated from your source,
and it should never go into a repo. Anyone can regenerate it by running `javac`. So
exclude it first:

```bash
echo "*.class" > .gitignore
```

Run `git status` again and watch `Hello.class` disappear from the list. Then:

```bash
git add .
```

```bash
git commit -m "My first Java program"
```

---

## 11. Now open it in IntelliJ

Only now:

```bash
idea .
```

(On Windows: **File → Open** and pick the `first-program` folder.)

Watch what the IDE does *for* you. It compiles in the background, so the green Run
arrow just works. It flags `cannot find symbol` with a red squiggle as you type, instead
of making you run `javac`. Type `psvm` and press Tab — it writes the entire `main`
signature for you.

That shortcut is only safe now. You know what it's typing, and why every word of it is
there.

---

## What you should be able to do now

- [ ] Create a `.java` file from nothing and explain why its name must match the class
- [ ] Explain what `public`, `static`, `void`, `main` and `String[] args` each do
- [ ] Compile with `javac` and run with `java`, and say what `.class` is
- [ ] Tell a compile-time error from a runtime error, and give an example of each
- [ ] Read a compiler error and find the line it's pointing at
- [ ] Pass an argument on the command line and read it in your program
- [ ] Keep build artifacts out of a Git repo

If any of those is shaky, do the exercise again from an empty folder. It takes ten
minutes the second time.
