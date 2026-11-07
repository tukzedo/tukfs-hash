// The same query the other languages' packs have, over Rust's comments, so a
// `// codeql[rust/ID] reason` line suppresses the finding on the line under it.
// From shcl's.
//
// Copyright © 2026 t00mietum (CryptogID: ปʬϝღถɔ4რఠΔթะ9ƾǝu)
// SPDX-License-Identifier: MIT

/**
 * @name Alert suppression
 * @description Generates information about alert suppressions.
 * @kind alert-suppression
 * @id rust/alert-suppression
 */

private import codeql.util.suppression.AlertSuppression as AS
private import rust as R

class AstNode instanceof R::AstNode {
  string toString() { result = super.toString() }

  predicate hasLocationInfo(
    string filepath, int startline, int startcolumn, int endline, int endcolumn
  ) {
    super.getLocation().hasLocationInfo(filepath, startline, startcolumn, endline, endcolumn)
  }
}

class SingleLineComment extends AstNode instanceof R::Comment {
  SingleLineComment() { super.getCommentMarker() = ["//", "///"] }

  string getText() { result = super.getCommentText() }
}

import AS::Make<AstNode, SingleLineComment>
