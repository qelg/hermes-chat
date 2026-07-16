import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

class AssistantMarkdown extends StatelessWidget {
  const AssistantMarkdown({super.key, required this.data});

  final String data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final baseStyle = MarkdownStyleSheet.fromTheme(theme);

    return MarkdownBody(
      data: data,
      selectable: true,
      softLineBreak: true,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      builders: {'pre': _CodeBlockBuilder()},
      imageBuilder: (uri, title, alt) => Tooltip(
        message: alt?.isNotEmpty == true ? alt! : 'Remote image hidden',
        child: Icon(
          Icons.image_not_supported_outlined,
          size: 20,
          color: colors.onSurfaceVariant,
        ),
      ),
      onTapLink: (_, href, _) {
        if (href != null) unawaited(_openSafeLink(href));
      },
      styleSheet: baseStyle.copyWith(
        a: baseStyle.a?.copyWith(
          color: colors.primary,
          decoration: TextDecoration.underline,
          decorationColor: colors.primary,
        ),
        code: baseStyle.code?.copyWith(
          fontFamily: 'monospace',
          color: colors.onSurface,
          backgroundColor: colors.surfaceContainerHighest,
        ),
        codeblockDecoration: const BoxDecoration(),
        blockquoteDecoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
          border: Border(left: BorderSide(color: colors.primary, width: 3)),
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
        tableColumnWidth: const IntrinsicColumnWidth(),
        tableScrollbarThumbVisibility: true,
        tableBorder: TableBorder.all(color: colors.outlineVariant),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
      ),
    );
  }
}

Future<void> _openSafeLink(String href) async {
  final uri = Uri.tryParse(href);
  if (uri == null || !isSafeAssistantLink(uri)) {
    return;
  }
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Exception {
    // A malformed or unavailable external target must not break the chat UI.
  }
}

bool isSafeAssistantLink(Uri uri) =>
    const {'http', 'https', 'mailto'}.contains(uri.scheme);

class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    final colors = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: 'Copy code',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy_rounded, size: 18),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code));
                if (context.mounted) {
                  ScaffoldMessenger.maybeOf(
                    context,
                  )?.showSnackBar(const SnackBar(content: Text('Code copied')));
                }
              },
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SelectableText(
              code,
              style: (preferredStyle ?? parentStyle)?.copyWith(
                fontFamily: 'monospace',
                backgroundColor: Colors.transparent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
