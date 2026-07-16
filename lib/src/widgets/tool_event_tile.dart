import 'package:flutter/material.dart';
import '../models.dart';

IconData toolIconForName(String? rawName) {
  final name = (rawName ?? '')
      .toLowerCase()
      .split('.')
      .last
      .replaceAll('-', '_');

  if (name == 'terminal' || name == 'process' || name == 'execute_code') {
    return Icons.terminal_rounded;
  }
  if (name == 'read_file') return Icons.description_outlined;
  if (name == 'write_file' || name == 'patch') return Icons.edit_note_rounded;
  if (name == 'search_files') return Icons.folder_open_outlined;
  if (name.startsWith('web_') ||
      name.startsWith('browser_') ||
      name.startsWith('computer_')) {
    return Icons.public_rounded;
  }
  if (name.startsWith('github') || name.startsWith('git_')) {
    return Icons.account_tree_outlined;
  }
  if (name.startsWith('image_') || name == 'vision_analyze') {
    return Icons.image_outlined;
  }
  if (name.contains('audio') ||
      name.contains('speech') ||
      name.startsWith('voice_')) {
    return Icons.audio_file_outlined;
  }
  if (name.contains('video')) return Icons.movie_outlined;
  if (name == 'cronjob' ||
      name.startsWith('schedule_') ||
      name.startsWith('calendar_')) {
    return Icons.calendar_month_outlined;
  }
  return Icons.build_outlined;
}

class ToolEventTile extends StatelessWidget {
  const ToolEventTile({super.key, required this.event});

  final ChatEvent event;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.white.withValues(alpha: 0.025),
        shape: RoundedRectangleBorder(
          side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          dense: true,
          leading: Icon(toolIconForName(event.toolName), size: 17),
          title: Text(
            event.summary,
            style: Theme.of(context).textTheme.labelMedium,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                event.details,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ToolGroupTile extends StatelessWidget {
  const ToolGroupTile({super.key, required this.group});

  final ToolGroupTimelineBlock group;

  @override
  Widget build(BuildContext context) {
    final breakdown = group.counts.entries
        .map((entry) => '${entry.key} ×${entry.value}')
        .join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white.withValues(alpha: 0.035),
        shape: RoundedRectangleBorder(
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          borderRadius: BorderRadius.circular(10),
        ),
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          leading: const Icon(Icons.build_circle_outlined, size: 19),
          title: Text(
            '${group.callCount} tool calls',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          subtitle: Text(
            breakdown,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          children: group.events
              .map((event) => ToolEventTile(event: event))
              .toList(growable: false),
        ),
      ),
    );
  }
}
