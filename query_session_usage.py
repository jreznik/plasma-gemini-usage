#!/usr/bin/env python3
"""
Copyright (C) 2026 Jaroslav Reznik

query_session_usage.py - Programmatic Session Telemetry & Context Usage Utility

This script parses the active Antigravity session's transcript logs to calculate
total token consumption, remaining context window limits, and category breakdowns.
It mimics typing `/usage` in the chat UI and can be run programmatically.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
"""

import os
import sys
import json
import glob
import argparse

DEFAULT_BRAIN_DIR = os.path.expanduser("~/.gemini/antigravity-cli/brain")
DEFAULT_TOKEN_LIMIT = 2000000
DEFAULT_CHAR_FACTOR = 4.0  # standard heuristic: 4 characters per token

def get_latest_conversation():
    """Auto-detects the most recently modified conversation directory containing active logs."""
    if not os.path.exists(DEFAULT_BRAIN_DIR):
        return None
    
    # List all subfolders in DEFAULT_BRAIN_DIR
    dirs = [d for d in glob.glob(os.path.join(DEFAULT_BRAIN_DIR, "*")) if os.path.isdir(d)]
    if not dirs:
        return None
    
    # Only consider directories that contain a valid transcript log file
    valid_dirs = []
    for d in dirs:
        log_file = os.path.join(d, ".system_generated", "logs", "transcript.jsonl")
        if os.path.exists(log_file):
            valid_dirs.append(d)
            
    if not valid_dirs:
        # Fallback to general sorting if no active log directories found yet
        dirs.sort(key=lambda x: os.path.getmtime(x), reverse=True)
        return os.path.basename(dirs[0])
    
    # Sort by modification time (most recent first)
    valid_dirs.sort(key=lambda x: os.path.getmtime(x), reverse=True)
    return os.path.basename(valid_dirs[0])

def parse_transcript(conv_id, char_factor, token_limit):
    """Parses transcript.jsonl and calculates categorised token metrics."""
    conv_dir = os.path.join(DEFAULT_BRAIN_DIR, conv_id)
    log_path = os.path.join(conv_dir, ".system_generated", "logs", "transcript.jsonl")
    
    if not os.path.exists(log_path):
        return {
            "status": "error",
            "message": f"Log file not found at: {log_path}"
        }
    
    categories = {
        "user_prompts": {"chars": 0, "tokens": 0},
        "agent_responses": {"chars": 0, "tokens": 0},
        "tool_outputs": {"chars": 0, "tokens": 0},
        "system_meta": {"chars": 0, "tokens": 0}
    }
    
    steps_count = 0
    
    with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                steps_count += 1
                t = obj.get("type", "")
                content = obj.get("content", "")
                if content is None:
                    content = ""
                if not isinstance(content, str):
                    content = str(content)
                length = len(content)
                
                # Check tool calls inside model planner responses
                tool_calls = obj.get("tool_calls", []) or []
                for tc in tool_calls:
                    length += len(tc.get("name", "")) + len(json.dumps(tc.get("args", {})))
                
                # Categorise step type
                if t == "USER_INPUT":
                    categories["user_prompts"]["chars"] += length
                elif t == "PLANNER_RESPONSE":
                    categories["agent_responses"]["chars"] += length
                elif t in ["RUN_COMMAND", "VIEW_FILE", "CODE_ACTION", "SEARCH_WEB", "LIST_DIRECTORY", "GREP_SEARCH", "GENERIC"]:
                    categories["tool_outputs"]["chars"] += length
                else:
                    categories["system_meta"]["chars"] += length
                    
            except Exception:
                pass
                
    # Compute token values using heuristic factor
    total_chars = 0
    total_tokens = 0
    
    for k in categories:
        chars = categories[k]["chars"]
        tokens = int(chars / char_factor)
        categories[k]["tokens"] = tokens
        total_chars += chars
        total_tokens += tokens
        
    percentage_used = (total_tokens / token_limit) * 100
    tokens_remaining = max(0, token_limit - total_tokens)
    
    # Compute breakdown percentages
    for k in categories:
        categories[k]["percentage"] = (categories[k]["tokens"] / total_tokens * 100) if total_tokens > 0 else 0.0
        
    return {
        "status": "success",
        "conversation_id": conv_id,
        "log_file": log_path,
        "steps_count": steps_count,
        "characters_count": total_chars,
        "tokens_limit": token_limit,
        "tokens_estimated": total_tokens,
        "tokens_remaining": tokens_remaining,
        "percentage_used": round(percentage_used, 2),
        "breakdown": categories
    }

def print_terminal_dashboard(data):
    """Prints a beautiful terminal dashboard with HSL style bars and details."""
    # Terminal formatting colors
    C_BLUE = "\033[94m"
    C_CYAN = "\033[96m"
    C_GREEN = "\033[92m"
    C_YELLOW = "\033[93m"
    C_RED = "\033[91m"
    C_BOLD = "\033[1m"
    C_RESET = "\033[0m"
    
    conv_id = data["conversation_id"]
    steps = data["steps_count"]
    total_chars = data["characters_count"]
    total_tokens = data["tokens_estimated"]
    token_limit = data["tokens_limit"]
    remaining = data["tokens_remaining"]
    pct = data["percentage_used"]
    
    print(f"{C_BOLD}{C_BLUE}=================================================================={C_RESET}")
    print(f"  {C_BOLD}🚀 ANTIGRAVITY SESSION TELEMETRY & CONTEXT DASHBOARD{C_RESET}")
    print(f"{C_BOLD}{C_BLUE}=================================================================={C_RESET}")
    print(f"{C_BOLD}Active Session ID:{C_RESET} {C_CYAN}{conv_id}{C_RESET}")
    print(f"{C_BOLD}Steps Parsed:{C_RESET}      {steps} timeline increments")
    print(f"{C_BOLD}Total Characters:{C_RESET}  {total_chars:,} raw log characters")
    print()
    
    # Build beautiful context usage bar
    bar_width = 40
    filled_width = int(round(pct / 100.0 * bar_width))
    filled_width = min(bar_width, max(0, filled_width))
    empty_width = bar_width - filled_width
    
    # Color active bar based on fullness
    bar_color = C_GREEN
    if pct > 75:
        bar_color = C_RED
    elif pct > 45:
        bar_color = C_YELLOW
        
    bar_str = f"{bar_color}{'█' * filled_width}{C_RESET}{'░' * empty_width}"
    
    print(f"{C_BOLD}CONTEXT WINDOW CAPACITY:{C_RESET}")
    print(f"[{bar_str}] {C_BOLD}{pct:.2f}%{C_RESET} Used")
    print()
    print(f" - {C_BOLD}Tokens Consumed (Est.):{C_RESET}  {C_BOLD}{bar_color}{total_tokens:,}{C_RESET} / {C_BOLD}{token_limit:,}{C_RESET}")
    print(f" - {C_BOLD}Tokens Remaining (Est.):{C_RESET} {C_BOLD}{C_GREEN}{remaining:,}{C_RESET}")
    print()
    print(f"{C_BOLD}CATEGORY BREAKDOWN:{C_RESET}")
    print(f"{C_BLUE}------------------------------------------------------------------{C_RESET}")
    print(f"{C_BOLD}{'Category':<32} {'Estimated Tokens':<18} {'Ratio':<10}{C_RESET}")
    print(f"{C_BLUE}------------------------------------------------------------------{C_RESET}")
    
    breakdown_labels = {
        "user_prompts": "User Prompts & Metadata",
        "agent_responses": "Agent Thoughts & Reasoning",
        "tool_outputs": "Tool Executions & Outputs",
        "system_meta": "System & Conversation Meta"
    }
    
    colors = {
        "user_prompts": C_CYAN,
        "agent_responses": C_YELLOW,
        "tool_outputs": C_GREEN,
        "system_meta": "\033[90m"  # gray
    }
    
    for k, label in breakdown_labels.items():
        sub = data["breakdown"][k]
        tokens = sub["tokens"]
        sub_pct = sub["percentage"]
        color = colors[k]
        print(f"{color}{label:<32}{C_RESET} {tokens:<18,} {sub_pct:.1f}%")
        
    print(f"{C_BLUE}------------------------------------------------------------------{C_RESET}")
    print(f"{C_BOLD}{C_GREEN}Status: Operational. Compaction safe.{C_RESET}")
    print(f"{C_BOLD}{C_BLUE}=================================================================={C_RESET}")

def main():
    parser = argparse.ArgumentParser(description="Query Antigravity token usage programmatically.")
    parser.add_argument("-c", "--conversation", help="Specify a conversation session ID")
    parser.add_argument("-j", "--json", action="store_true", help="Output raw telemetry as JSON")
    parser.add_argument("-f", "--factor", type=float, default=DEFAULT_CHAR_FACTOR, help="Characters to token heuristic factor")
    parser.add_argument("-l", "--limit", type=int, default=DEFAULT_TOKEN_LIMIT, help="Session token limit (default 2,000,000)")
    
    args = parser.parse_args()
    
    conv_id = args.conversation
    if not conv_id:
        conv_id = get_latest_conversation()
        
    if not conv_id:
        error_res = {
            "status": "error",
            "message": "No conversation folders found. Ensure you are running within an active Antigravity workspace."
        }
        if args.json:
            print(json.dumps(error_res, indent=2))
        else:
            print(f"Error: {error_res['message']}", file=sys.stderr)
        sys.exit(1)
        
    res = parse_transcript(conv_id, args.factor, args.limit)
    
    if args.json:
        print(json.dumps(res, indent=2))
    else:
        if res.get("status") == "error":
            print(f"Error: {res.get('message')}", file=sys.stderr)
            sys.exit(1)
        print_terminal_dashboard(res)

if __name__ == "__main__":
    main()
