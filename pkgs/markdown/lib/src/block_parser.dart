// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library markdown.block_parser;

import 'ast.dart';
import 'document.dart';
import 'util.dart';

/// The line contains only whitespace or is empty.
final _emptyPattern = new RegExp(r'^(?:[ \t]*)$');

/// A series of `=` or `-` (on the next line) define setext-style headers.
final _setextPattern = new RegExp(r'^(=+|-+)$');

/// Leading (and trailing) `#` define atx-style headers.
///
/// Starts with 1-6 unescaped `#` characters which must not be followed by a
/// non-space character. Line may end with any number of `#` characters,.
final _headerPattern = new RegExp(r'^(#{1,6})[ \x09\x0b\x0c](.*?)#*$');

/// The line starts with `>` with one optional space after.
final _blockquotePattern = new RegExp(r'^[ ]{0,3}>[ ]?(.*)$');

/// A line indented four spaces. Used for code blocks and lists.
final _indentPattern = new RegExp(r'^(?:    |\t)(.*)$');

/// Fenced code block.
final _codePattern = new RegExp(r'^[ ]{0,3}(`{3,}|~{3,})(.*)$');

/// Three or more hyphens, asterisks or underscores by themselves. Note that
/// a line like `----` is valid as both HR and SETEXT. In case of a tie,
/// SETEXT should win.
final _hrPattern = new RegExp(r'^ {0,3}([-*_]) *\1 *\1(?:\1| )*$');

/// A line starting with one of these markers: `-`, `*`, `+`. May have up to
/// three leading spaces before the marker and any number of spaces or tabs
/// after.
final _ulPattern = new RegExp(r'^[ ]{0,3}[*+-][ \t]+(.*)$');

/// A line starting with a number like `123.`. May have up to three leading
/// spaces before the marker and any number of spaces or tabs after.
final _olPattern = new RegExp(r'^[ ]{0,3}\d+\.[ \t]+(.*)$');

/// Maintains the internal state needed to parse a series of lines into blocks
/// of Markdown suitable for further inline parsing.
class BlockParser {
  final List<String> lines;

  /// The Markdown document this parser is parsing.
  final Document document;

  /// The enabled block syntaxes.
  ///
  /// To turn a series of lines into blocks, each of these will be tried in
  /// turn. Order matters here.
  final List<BlockSyntax> blockSyntaxes = [];

  /// Index of the current line.
  int _pos = 0;

  /// The collection of built-in block parsers.
  final List<BlockSyntax> standardBlockSyntaxes = [
    const EmptyBlockSyntax(),
    const BlockTagBlockHtmlSyntax(),
    new LongBlockHtmlSyntax(r'^ {0,3}<pre(?:\s|>|$)', '</pre>'),
    new LongBlockHtmlSyntax(r'^ {0,3}<script(?:\s|>|$)', '</script>'),
    new LongBlockHtmlSyntax(r'^ {0,3}<style(?:\s|>|$)', '</style>'),
    new LongBlockHtmlSyntax('^ {0,3}<!--', '-->'),
    new LongBlockHtmlSyntax('^ {0,3}<\\?', '\\?>'),
    new LongBlockHtmlSyntax('^ {0,3}<![A-Z]', '>'),
    new LongBlockHtmlSyntax('^ {0,3}<!\\[CDATA\\[', '\\]\\]>'),
    const OtherTagBlockHtmlSyntax(),
    const SetextHeaderSyntax(),
    const HeaderSyntax(),
    const CodeBlockSyntax(),
    const BlockquoteSyntax(),
    const HorizontalRuleSyntax(),
    const UnorderedListSyntax(),
    const OrderedListSyntax(),
    const ParagraphSyntax()
  ];

  BlockParser(this.lines, this.document) {
    blockSyntaxes.addAll(document.blockSyntaxes);
    blockSyntaxes.addAll(standardBlockSyntaxes);
  }

  /// Gets the current line.
  String get current => lines[_pos];

  /// Gets the line after the current one or `null` if there is none.
  String get next {
    // Don't read past the end.
    if (_pos >= lines.length - 1) return null;
    return lines[_pos + 1];
  }

  /// Gets the line that is [linesAhead] lines ahead of the current one, or
  /// `null` if there is none.
  ///
  /// `peek(0)` is equivalent to [current].
  ///
  /// `peek(1)` is equivalent to [next].
  String peek(int linesAhead) {
    if (linesAhead < 0)
      throw new ArgumentError('Invalid linesAhead: $linesAhead; must be >= 0.');
    // Don't read past the end.
    if (_pos >= lines.length - linesAhead) return null;
    return lines[_pos + linesAhead];
  }

  void advance() {
    _pos++;
  }

  bool get isDone => _pos >= lines.length;

  /// Gets whether or not the current line matches the given pattern.
  bool matches(RegExp regex) {
    if (isDone) return false;
    return regex.firstMatch(current) != null;
  }

  /// Gets whether or not the next line matches the given pattern.
  bool matchesNext(RegExp regex) {
    if (next == null) return false;
    return regex.firstMatch(next) != null;
  }
}

abstract class BlockSyntax {
  const BlockSyntax();

  /// Gets the regex used to identify the beginning of this block, if any.
  RegExp get pattern => null;

  bool get canEndBlock => true;

  bool canParse(BlockParser parser) {
    return pattern.firstMatch(parser.current) != null;
  }

  Node parse(BlockParser parser);

  List<String> parseChildLines(BlockParser parser) {
    // Grab all of the lines that form the blockquote, stripping off the ">".
    var childLines = <String>[];

    while (!parser.isDone) {
      var match = pattern.firstMatch(parser.current);
      if (match == null) break;
      childLines.add(match[1]);
      parser.advance();
    }

    return childLines;
  }

  /// Gets whether or not [parser]'s current line should end the previous block.
  static bool isAtBlockEnd(BlockParser parser) {
    if (parser.isDone) return true;
    return parser.blockSyntaxes.any((s) => s.canParse(parser) && s.canEndBlock);
  }

  /// Generates a valid HTML anchor from the inner text of [element].
  static String generateAnchorHash(Element element) =>
      _concatenatedText(element)
          .toLowerCase()
          .trim()
          .replaceFirst(new RegExp(r'^[^a-z]+'), '')
          .replaceAll(new RegExp(r'[^a-z0-9 _-]'), '')
          .replaceAll(new RegExp(r'\s'), '-');

  /// Concatenates the text found in all the children of [element].
  static String _concatenatedText(Element element) => element.children
      .map((child) => (child is Text) ? child.text : _concatenatedText(child))
      .join('');
}

class EmptyBlockSyntax extends BlockSyntax {
  RegExp get pattern => _emptyPattern;

  const EmptyBlockSyntax();

  Node parse(BlockParser parser) {
    parser.advance();

    // Don't actually emit anything.
    return null;
  }
}

/// Parses setext-style headers.
class SetextHeaderSyntax extends BlockSyntax {
  const SetextHeaderSyntax();

  bool canParse(BlockParser parser) {
    // Note: matches *next* line, not the current one. We're looking for the
    // underlining after this line.
    return parser.matchesNext(_setextPattern) &&
        // The current line must look like a paragraph.
        !(parser.matches(_codePattern) ||
            parser.matches(_headerPattern) ||
            parser.matches(_blockquotePattern) ||
            parser.matches(_hrPattern) ||
            parser.matches(_ulPattern) ||
            parser.matches(_olPattern));
  }

  Node parse(BlockParser parser) {
    var match = _setextPattern.firstMatch(parser.next);

    var tag = (match[1][0] == '=') ? 'h1' : 'h2';
    var contents = parser.document.parseInline(parser.current);
    parser.advance();
    parser.advance();

    return new Element(tag, contents);
  }
}

/// Parses setext-style headers, and adds generated IDs to the generated
/// elements.
class SetextHeaderWithIdSyntax extends SetextHeaderSyntax {
  const SetextHeaderWithIdSyntax();

  Node parse(BlockParser parser) {
    var element = super.parse(parser) as Element;
    element.generatedId = BlockSyntax.generateAnchorHash(element);
    return element;
  }
}

/// Parses atx-style headers: `## Header ##`.
class HeaderSyntax extends BlockSyntax {
  RegExp get pattern => _headerPattern;

  const HeaderSyntax();

  Node parse(BlockParser parser) {
    var match = pattern.firstMatch(parser.current);
    parser.advance();
    var level = match[1].length;
    var contents = parser.document.parseInline(match[2].trim());
    return new Element('h$level', contents);
  }
}

/// Parses atx-style headers, and adds generated IDs to the generated elements.
class HeaderWithIdSyntax extends HeaderSyntax {
  const HeaderWithIdSyntax();

  Node parse(BlockParser parser) {
    var element = super.parse(parser) as Element;
    element.generatedId = BlockSyntax.generateAnchorHash(element);
    return element;
  }
}

/// Parses email-style blockquotes: `> quote`.
class BlockquoteSyntax extends BlockSyntax {
  RegExp get pattern => _blockquotePattern;

  const BlockquoteSyntax();

  List<String> parseChildLines(BlockParser parser) {
    // Grab all of the lines that form the blockquote, stripping off the ">".
    var childLines = <String>[];

    while (!parser.isDone) {
      var match = pattern.firstMatch(parser.current);
      if (match != null) {
        childLines.add(match[1]);
        parser.advance();
        continue;
      }

      // A paragraph continuation is OK. This is content that cannot be parsed
      // as any other syntax except Paragraph, and it doesn't match the bar in
      // a Setext header.
      if (parser.blockSyntaxes.firstWhere((s) => s.canParse(parser))
          is ParagraphSyntax) {
        var continuedLine = childLines.last + parser.current;
        childLines
          ..removeLast()
          ..add(continuedLine);
        parser.advance();
      } else {
        break;
      }
    }

    return childLines;
  }

  Node parse(BlockParser parser) {
    var childLines = parseChildLines(parser);

    // Recursively parse the contents of the blockquote.
    var children = parser.document.parseLines(childLines);

    return new Element('blockquote', children);
  }
}

/// Parses preformatted code blocks that are indented four spaces.
class CodeBlockSyntax extends BlockSyntax {
  RegExp get pattern => _indentPattern;

  bool get canEndBlock => false;

  const CodeBlockSyntax();

  List<String> parseChildLines(BlockParser parser) {
    var childLines = <String>[];

    while (!parser.isDone) {
      var match = pattern.firstMatch(parser.current);
      if (match != null) {
        childLines.add(match[1]);
        parser.advance();
      } else {
        // If there's a codeblock, then a newline, then a codeblock, keep the
        // code blocks together.
        var nextMatch =
            parser.next != null ? pattern.firstMatch(parser.next) : null;
        if (parser.current.trim() == '' && nextMatch != null) {
          childLines.add('');
          childLines.add(nextMatch[1]);
          parser.advance();
          parser.advance();
        } else {
          break;
        }
      }
    }
    return childLines;
  }

  Node parse(BlockParser parser) {
    var childLines = parseChildLines(parser);

    // The Markdown tests expect a trailing newline.
    childLines.add('');

    // Escape the code.
    var escaped = escapeHtml(childLines.join('\n'));

    return new Element('pre', [new Element.text('code', escaped)]);
  }
}

/// Parses preformatted code blocks between two ~~~ or ``` sequences.
///
/// See [Pandoc's documentation](http://pandoc.org/README.html#fenced-code-blocks).
class FencedCodeBlockSyntax extends BlockSyntax {
  RegExp get pattern => _codePattern;

  const FencedCodeBlockSyntax();

  List<String> parseChildLines(BlockParser parser, [String endBlock]) {
    if (endBlock == null) endBlock = '';

    var childLines = <String>[];
    parser.advance();

    while (!parser.isDone) {
      var match = pattern.firstMatch(parser.current);
      if (match == null || !match[1].startsWith(endBlock)) {
        childLines.add(parser.current);
        parser.advance();
      } else {
        parser.advance();
        break;
      }
    }

    return childLines;
  }

  Node parse(BlockParser parser) {
    // Get the syntax identifier, if there is one.
    var match = pattern.firstMatch(parser.current);
    var endBlock = match.group(1);
    var infoString = match.group(2);

    var childLines = parseChildLines(parser, endBlock);

    // The Markdown tests expect a trailing newline.
    childLines.add('');

    // Escape the code.
    var escaped = escapeHtml(childLines.join('\n'));

    var code = new Element.text('code', escaped);

    // the info-string should be trimmed
    // http://spec.commonmark.org/0.22/#example-100
    infoString = infoString.trim();
    if (infoString.isNotEmpty) {
      // only use the first word in the syntax
      // http://spec.commonmark.org/0.22/#example-100
      infoString = infoString.split(' ').first;
      code.attributes['class'] = "language-$infoString";
    }

    var element = new Element('pre', [code]);

    return element;
  }
}

/// Parses horizontal rules like `---`, `_ _ _`, `*  *  *`, etc.
class HorizontalRuleSyntax extends BlockSyntax {
  RegExp get pattern => _hrPattern;

  const HorizontalRuleSyntax();

  Node parse(BlockParser parser) {
    parser.advance();
    return new Element.empty('hr');
  }
}

/// Parses inline HTML at the block level. This differs from other Markdown
/// implementations in several ways:
///
/// 1.  This one is way way WAY simpler.
/// 2.  Essentially no HTML parsing or validation is done. We're a Markdown
///     parser, not an HTML parser!
abstract class BlockHtmlSyntax extends BlockSyntax {
  bool get canEndBlock => true;

  const BlockHtmlSyntax();
}

class BlockTagBlockHtmlSyntax extends BlockHtmlSyntax {
  RegExp get pattern => new RegExp(
      r'^ {0,3}</?(?:address|article|aside|base|basefont|blockquote|body|'
      r'caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|'
      r'figcaption|figure|footer|form|frame|frameset|h1|head|header|hr|html|'
      r'iframe|legend|li|link|main|menu|menuitem|meta|nav|noframes|ol|optgroup|'
      r'option|p|param|section|source|summary|table|tbody|td|tfoot|th|thead|'
      'title|tr|track|ul)'
      r'(?:\s|>|/>|$)');

  const BlockTagBlockHtmlSyntax();

  Node parse(BlockParser parser) {
    var childLines = <String>[];

    // Eat until we hit a blank line.
    while (!parser.isDone && !parser.matches(_emptyPattern)) {
      childLines.add(parser.current);
      parser.advance();
    }

    return new Text(childLines.join('\n'));
  }
}

class OtherTagBlockHtmlSyntax extends BlockTagBlockHtmlSyntax {
  bool get canEndBlock => false;

  // Really hacky way to detect "other" HTML. This matches:
  //
  // * any opening spaces
  // * open bracket and maybe a slash ("<" or "</")
  // * some word characters
  // * either:
  //   * a close bracket, or
  //   * whitespace followed by not-brackets follwed by a close bracket
  // * possible whitespace and the end of the line.
  RegExp get pattern => new RegExp(r'^ {0,3}</?\w+(?:>|\s+[^>]*>)\s*$');

  const OtherTagBlockHtmlSyntax();
}

/// A BlockHtmlSyntax that has a specific [endPattern].
///
/// In practice this means that the syntax dominates; it is allowed to eat
/// many lines, including blank lines, before matching its [endPattern].
class LongBlockHtmlSyntax extends BlockHtmlSyntax {
  RegExp _pattern;
  RegExp _endPattern;

  LongBlockHtmlSyntax(pattern, endPattern) {
    _pattern = new RegExp(pattern);
    _endPattern = new RegExp(endPattern);
  }

  RegExp get pattern => _pattern;

  Node parse(BlockParser parser) {
    var childLines = <String>[];
    // Eat until we hit [endPattern].
    while (!parser.isDone) {
      childLines.add(parser.current);
      if (parser.matches(_endPattern)) break;
      parser.advance();
    }

    parser.advance();
    return new Text(childLines.join('\n'));
  }
}

class ListItem {
  bool forceBlock = false;
  final List<String> lines;

  ListItem(this.lines);
}

/// Base class for both ordered and unordered lists.
abstract class ListSyntax extends BlockSyntax {
  bool get canEndBlock => true;

  String get listTag;

  const ListSyntax();

  /// A list of patterns that can start a valid block within a list item.
  static final blocksInList = [
    _blockquotePattern,
    _headerPattern,
    _hrPattern,
    _indentPattern,
    _ulPattern,
    _olPattern
  ];

  Node parse(BlockParser parser) {
    var items = <ListItem>[];
    var childLines = <String>[];

    endItem() {
      if (childLines.length > 0) {
        items.add(new ListItem(childLines));
        childLines = <String>[];
      }
    }

    var match;
    tryMatch(RegExp pattern) {
      match = pattern.firstMatch(parser.current);
      return match != null;
    }

    while (!parser.isDone) {
      if (tryMatch(_emptyPattern)) {
        // Add a blank line to the current list item.
        childLines.add('');
      } else if (tryMatch(_ulPattern) || tryMatch(_olPattern)) {
        // End the current list item and start a new one.
        endItem();
        childLines.add(match[1]);
      } else if (tryMatch(_indentPattern)) {
        // Strip off indent and add to current item.
        childLines.add(match[1]);
      } else if (BlockSyntax.isAtBlockEnd(parser)) {
        // Done with the list.
        break;
      } else {
        // If the previous item is a blank line, this means we're done with the
        // list and are starting a new top-level paragraph.
        if ((childLines.isNotEmpty) && (childLines.last == '')) break;

        // Anything else is paragraph continuation text.
        var continuedLine = childLines.last + parser.current;
        childLines
          ..removeLast()
          ..add(continuedLine);
      }
      parser.advance();
    }

    endItem();
    determineBlockItems(items);
    var itemNodes = <Node>[];

    for (var item in items) {
      if (item.forceBlock) {
        // Block list item.
        var children = parser.document.parseLines(item.lines);
        itemNodes.add(new Element('li', children));
      } else {
        // Raw list item.
        var contents = parser.document.parseInline(item.lines[0]);
        itemNodes.add(new Element('li', contents));
      }
    }

    return new Element(listTag, itemNodes);
  }

  /// Determines whether each item in [items] is a block item.
  ///
  /// Also removes any trailing empty lines and notes which items are separated
  /// by empty lines.
  void determineBlockItems(List items) {
    // Markdown, because it hates us, specifies two kinds of list items. If you
    // have a list like:
    //
    // * one
    // * two
    //
    // Then it will insert the contents of the lines directly in the <li>, like:
    //
    // <ul>
    //   <li>one</li>
    //   <li>two</li>
    // <ul>
    //
    // If, however, there are blank lines between the items, each is wrapped in
    // paragraphs:
    //
    // * one
    //
    // * two
    //
    // <ul>
    //   <li><p>one</p></li>
    //   <li><p>two</p></li>
    // <ul>
    //
    // In other words, sometimes we parse the contents of a list item like a
    // block, and sometimes line an inline. The rules our parser implements are:
    //
    // - If it has more than one line, it's a block.
    // - If the line matches any block parser (BLOCKQUOTE, HEADER, HR, INDENT,
    //   UL, OL) it's a block. (This is for cases like "* > quote".)
    // - If there was a blank line between this item and the previous one, it's
    //   a block.
    // - If there was a blank line between this item and the next one, it's a
    //   block.
    // - Otherwise, parse it as an inline.

    // Remove any trailing empty lines and note which items are separated by
    // empty lines. Do this before seeing which items are single-line so that
    // trailing empty lines on the last item don't force it into being a block.
    for (var i = 0; i < items.length; i++) {
      for (var j = items[i].lines.length - 1; j > 0; j--) {
        if (!_emptyPattern.hasMatch(items[i].lines[j])) break;

        // Found an empty line. This item and the one after it are blocks.
        if (i < items.length - 1) {
          items[i].forceBlock = true;
          items[i + 1].forceBlock = true;
        }
        items[i].lines.removeLast();
      }

      // Items with more than one line are block items.
      items[i].forceBlock = items[i].forceBlock || items[i].lines.length > 1;

      if (items[i].forceBlock) continue;

      // Items (even one-lined items) that start with a block syntax are block
      // items.
      items[i].forceBlock =
          blocksInList.any((p) => p.hasMatch(items[i].lines[0]));
    }
  }
}

/// Parses unordered lists.
class UnorderedListSyntax extends ListSyntax {
  RegExp get pattern => _ulPattern;
  String get listTag => 'ul';

  const UnorderedListSyntax();
}

/// Parses ordered lists.
class OrderedListSyntax extends ListSyntax {
  RegExp get pattern => _olPattern;
  String get listTag => 'ol';

  const OrderedListSyntax();
}

/// Parses paragraphs of regular text.
class ParagraphSyntax extends BlockSyntax {
  bool get canEndBlock => false;

  const ParagraphSyntax();

  bool canParse(BlockParser parser) => true;

  Node parse(BlockParser parser) {
    var childLines = <String>[];

    // Eat until we hit something that ends a paragraph.
    while (!BlockSyntax.isAtBlockEnd(parser)) {
      childLines.add(parser.current);
      parser.advance();
    }

    var contents = parser.document.parseInline(childLines.join('\n'));
    return new Element('p', contents);
  }
}
