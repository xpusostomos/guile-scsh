
This is a new idea for a shell. It is based on Olin Shivers scsh project, 
but with features that make it good for users to type into directly, as
an interactive shell.

The way it works is the user isn't typing just text, but the user types
into a scheme structured editor. Scheme forms are always balanced. various
keys help the user rearrange the form. M-TAB rearranges the parenthesis 
balance of the form. TAB completes the word at the cursor as a file name, the
way bash does it. | sets up an scsh pipeline form. & sets up a background 
form. Also the user can type various plain scheme to make things happen.
,variable allows you to print a regular variable.

There is a keymap that defines what keys do. This is how we add new features 
and decide what keys do. There is a history list like bash. There is job
control like bash. We are trying to make a shell that a user could
use as well as bash for interactive work.

Don't go and implement a good idea until the user gives the go ahead. Asking questions
that you think you have a good answer to doesn't mean you have permission to go and
build it.
