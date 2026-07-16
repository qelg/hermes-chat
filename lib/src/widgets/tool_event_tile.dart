import 'package:flutter/material.dart';
import '../models.dart';

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
          leading: const Icon(Icons.terminal_rounded, size: 17),
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
