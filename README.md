# Structured Scsh

Scheme heads have long had a dream ...  of having Scheme
everywhere. Scheme all the way down. Scheme in their
[editor](https://github.com/xpusostomos/schemacs), Scheme in their
[window manager](https://github.com/xpusostomos/Hyprscheme) and one
they wouldn't like to admit to... Scheme in their shell. The latter
is one of the most vexing because of course Scheme is rather
fastidious with its parens ().

Enter Structured scsh. The scheme shell with a structured editor.
Built upon Olin Shivers' excellent work in the 1990s, but with a
new twist. Olin's scsh was intellectualy satisfying, but difficult
to learn and too wordy to write interactively. Because of that
it didnt get a foothold in doing what it should be truly great at...
complex scripting.

Structured scsh uses a smart editor as your interactive shell.
If you type:
```ls``` 
the smart editor will replace that with
```(run (ls))```
If you type ```|``` the smart editor will change your form to:
```(run (| (ls) (_))``` 
with you ready to type the next part of the pipeline
The net effect is that if you type:
```ls *.c | wc >foo```
it gets expanded to:
```(run (| (ls ,@(eglob *.c)) (wc)) (> foo))```
It will do exactly what you think it will do... 

but not because it understands bash syntax. Rather because the
structured editor treats ```*``` and ```|``` and ```>``` as hotkeys to
rearrange your form to produce a valid scsh form. And it does it one
key at a time.  Once you see the forms dancing around at your every
keystroke you will quickly understand intuitively how scsh works.

The net effect is you could in fact use it legitimately as a 
daily driver shell. You can after all type regular commands
mostly the same as you would in bash, with the same number of
keystrokes and get the same result.

########

Scsh is a unix shell embedded in Scheme. What does that mean? Well, unix shells are powerful
tools. They allow a user to concisely specify her commands and the communications between them
(piping, redirecting, &c.). When she needs to do something more complex than running a set of
commands with known inputs, however, things become complicated. General programming with sh can be
unpleasant and error prone, to say the least.

Scheme is a simple, expressive general programming language. A user with some taste may want to use
it to wield her computing machine. For simple commands, however, it is not the most concise. At the
scale of the command line, even the overhead of parentheses matters. It would be nice to use each of
these languages where their strengths lie.

Scsh is the solution. It allows the user to write commands in a language within Scheme that follows
the unix way, but also allows her to specify more complex commands with the elegance of Scheme.

## A quick word from our lack of sponsors...

This project has been moderately expensive to implement in its use of
AI, and I'm running out of money to do it. If you want to see it move
forward, money, AI tokens or human assistence would help it move
forward much faster. Having said that, look at whats been achieved by
one guy in a short time.

## Developer Discussion

Github forum is turned on above, you should feel free to discuss the
project there.

Getting Started
===============


#### A short history of globbing

Globbing is the process of expanding file wildcards, typically ```*```
to a list of files.

* 1971-75 the shell called /etc/glob and if no files matched the shell
cancelled the command with "No match".
* 1978 csh built globbing into the shell and matched the behavior, a
  failed match of any glob cancelled the command and printed "No match". But it
  had an option nonomatch that passed the failed pattern to the
  command.
* 1979 bourne shell took a different approach, any unmatching pattern
  was passed directly to the command itself which typically would
  print "Not found" but depended entirely on which command it was.
* 1990 zsh comes out with csh-null-glob which means if any pattern matches,
  the command runs, if none match, it says no match, and null-glob which means
  run the command with no arguments if nothing matches.

Who was "correct"? In my opinion, they're all probably wrong, and unix
should have chosen to do globbing inside individual commands which
could then decide what makes sense. However we're not there, so out of
the options..

null-glob is clearly wrong, because if you type ls *.c, and see a full directory
listing, that is unexpected. Unfortunately that is what scsh's glob macro does.
Which is why Structured Ssh added eglob.

csh default is ok... but rather harsh. If you type ls *.c *.o and
there are .c files but no .o files, it says no match. Probably not
what you were hoping for.

bourne shell is clearly wrong... intellectually... but in practice
happens to generally give a sensible result, the command just prints
not found, and we move on. But commands don't generally expect to receive
a pattern, so passing them one is a bit of russian roulette. The command
```for i in * ; do echo there is a file called "$i" ; done``` oddly says
there is a file, whether there is a file called "*" or not!

In my opinion zsh's csh-null-glob is the correct answer. If something
matches, do it, if nothing does, fail. That's why Structured scsh
expands * to eglob, which is an extension to original scsh. But there
may be genuine cases for using basic glob when no results is what you
really want in the situation.
