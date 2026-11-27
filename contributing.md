<!-- markdownlint-disable MD007 -- Unordered list indentation -->
<!-- markdownlint-disable MD010 -- No hard tabs -->
<!-- markdownlint-disable MD041 -- First line in a file should be a top-level heading -->

# Contributing to tukfs-hash

Bug reports, questions, and pull requests are all welcome. This file says how each one goes. How the code is written is in the [code style guide](project/style-guide_code.md), and how the program is meant to work is in [design.md](project/design.md).

## Questions and bug reports

- Open an [issue](https://github.com/tukzedo/tukfs-hash/issues). Search the open and closed ones first, since the answer may already be there.

- A bug report needs these, so it can be reproduced:
	- The output of `tukfs-hash --version`.
	- The command as it was run, and its exit code.
	- The filesystem each root is on, such as ext4, btrfs, or ZFS, and whether it ran under sudo.
	- What it printed, and what was expected instead.

- A file reported as changed when it wasn't, or a changed file that a scan missed, is the worst kind of bug this tool can have. Say so in the title, and include the file's attributes from `getfattr -d -m user. FILE` if they're still there.

- For a security problem, open an issue that says only that there is one, and ask for a private way to send the details. Leave the details out of the public issue.

## Changes

- Set up the tools first, as README.md says under [Set up development environment](README.md#set-up-development-environment).

- Branch from `dev`, and send the pull request to `dev`. The `main` branch only gets releases, which are merged from `dev`.

- A bug fix comes with a test that fails before the fix and passes after it, wherever one can be written. A new test needs an ID, as the style guide says under "Tests".

- Run `cicd/cicd.bash --backlog-run-quick` before sending the pull request. It runs the format check, the build, every linter, and the tests. It doesn't change any tracked file, and it doesn't publish or install anything. A pull request isn't merged until it passes.

- A change in what the program does, or in what it writes to disk, needs README.md and design.md updated in the same pull request. Anything new that's written to a file or a filesystem should be called out in the pull request text, since this tool is run on data that people can't afford to lose.

- Keep a pull request to one change where you can. Commit messages are short and say what changed.

## License

- The program is licensed under [GPL-2.0-only](license.md). Most of the pipeline's scripts under `cicd/` are MIT. Each file's header says which license it's under.

- By sending a change, you agree that you wrote it, that you have the right to give it, and that it's licensed under the license in the header of each file it touches. A new file takes the header of a file of the same kind, as the style guide says.
