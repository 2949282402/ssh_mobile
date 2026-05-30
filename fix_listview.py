import re

with open('lib/screens/playbook_screen.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# Replace "child: ListView(" with "child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,"
# Note: we only want to replace the one inside _buildPlaybookEditor.
pattern = r"(Widget _buildPlaybookEditor.*?return Form\([^)]*child:\s*)ListView\(\s*padding:\s*const EdgeInsets\.all\(16\),\s*children:\s*\["

replacement = r"\g<1>SingleChildScrollView(\n        padding: const EdgeInsets.all(16),\n        child: Column(\n          crossAxisAlignment: CrossAxisAlignment.stretch,\n          children: ["

new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)

# Now we need to add the closing parenthesis for SingleChildScrollView.
# The end of that Form looks like:
#           const SizedBox(height: 48),
#         ],
#       ),
#     );
#   }
end_pattern = r"(\s*const SizedBox\(height: 48\),\n\s*],\n\s*\)),(\n\s*\);\n\s*})"
end_replacement = r"\g<1>,\n      )\g<2>"
new_content = re.sub(end_pattern, end_replacement, new_content, count=1)

with open('lib/screens/playbook_screen.dart', 'w', encoding='utf-8') as f:
    f.write(new_content)
