#!/usr/bin/env python3
"""Cloud to Disk Backup - Ingress Web UI"""

import json
import os
import glob
import subprocess
from datetime import datetime
from flask import Flask, render_template, jsonify, request, Response

app = Flask(__name__,
            template_folder='/usr/local/bin/web/templates',
            static_folder='/usr/local/bin/web/static')

INGRESS_PATH = os.environ.get('INGRESS_PATH', '')
STATUS_DIR = os.environ.get('ADDON_STATUS_DIR', '/data/status')
LOG_DIR = os.environ.get('ADDON_LOG_DIR', '/media/backup/logs')
DATA_DIR = os.environ.get('ADDON_DATA_DIR', '/data')
RCLONE_CONF = os.environ.get('ADDON_RCLONE_CONF', '/data/rclone.conf')


def get_all_status():
    """Read status files for all accounts."""
    statuses = []
    if os.path.isdir(STATUS_DIR):
        for f in sorted(glob.glob(os.path.join(STATUS_DIR, 'status_*.json'))):
            try:
                with open(f, 'r') as fh:
                    data = json.load(fh)
                    statuses.append(data)
            except (json.JSONDecodeError, IOError):
                name = os.path.basename(f).replace('status_', '').replace('.json', '')
                statuses.append({'account': name, 'status': 'unknown', 'message': 'Status file unreadable'})
    return statuses


def get_rclone_remotes():
    """List configured rclone remotes."""
    try:
        result = subprocess.run(
            ['rclone', 'listremotes', '--config', RCLONE_CONF],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            return [r.strip().rstrip(':') for r in result.stdout.strip().split('\n') if r.strip()]
    except Exception:
        pass
    return []


def get_disk_info(path):
    """Get disk usage info."""
    try:
        result = subprocess.run(['df', '-BG', path], capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            lines = result.stdout.strip().split('\n')
            if len(lines) >= 2:
                parts = lines[1].split()
                return {
                    'total': parts[1] if len(parts) > 1 else '?',
                    'used': parts[2] if len(parts) > 2 else '?',
                    'available': parts[3] if len(parts) > 3 else '?',
                    'percent': parts[4] if len(parts) > 4 else '?'
                }
    except Exception:
        pass
    return {'total': '?', 'used': '?', 'available': '?', 'percent': '?'}


def get_log_files(account=None):
    """List available log files."""
    pattern = f'backup_{account}_*.log' if account else 'backup_*.log'
    logs = sorted(glob.glob(os.path.join(LOG_DIR, pattern)), reverse=True)
    return [{'name': os.path.basename(l), 'path': l, 'size': os.path.getsize(l),
             'modified': datetime.fromtimestamp(os.path.getmtime(l)).isoformat()}
            for l in logs[:20]]


@app.route('/')
def index():
    """Main dashboard."""
    return render_template('index.html', ingress_path=INGRESS_PATH)


@app.route('/api/status')
def api_status():
    """API: Get all account statuses."""
    return jsonify({
        'accounts': get_all_status(),
        'disk': get_disk_info(os.environ.get('ADDON_BACKUP_PATH', '/media/backup')),
        'timestamp': datetime.now().isoformat()
    })


@app.route('/api/remotes')
def api_remotes():
    """API: List rclone remotes."""
    return jsonify({'remotes': get_rclone_remotes()})


@app.route('/api/logs')
def api_logs():
    """API: List log files."""
    account = request.args.get('account')
    return jsonify({'logs': get_log_files(account)})


@app.route('/api/logs/<path:filename>')
def api_log_content(filename):
    """API: Get log file content (last N lines)."""
    lines = int(request.args.get('lines', 100))
    filepath = os.path.join(LOG_DIR, os.path.basename(filename))
    if not os.path.isfile(filepath):
        return jsonify({'error': 'Log not found'}), 404
    try:
        result = subprocess.run(['tail', f'-n{lines}', filepath],
                                capture_output=True, text=True, timeout=5)
        return jsonify({'content': result.stdout, 'filename': filename})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/logs/<path:filename>/stream')
def api_log_stream(filename):
    """API: Stream log file (SSE)."""
    filepath = os.path.join(LOG_DIR, os.path.basename(filename))
    if not os.path.isfile(filepath):
        return jsonify({'error': 'Log not found'}), 404

    def generate():
        proc = subprocess.Popen(['tail', '-f', filepath],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            while True:
                line = proc.stdout.readline()
                if line:
                    yield f"data: {line.decode('utf-8', errors='replace').rstrip()}\n\n"
        except GeneratorExit:
            proc.kill()

    return Response(generate(), mimetype='text/event-stream',
                    headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'})


@app.route('/api/rclone/setup', methods=['POST'])
def api_rclone_setup():
    """API: Start rclone config for a provider."""
    data = request.get_json()
    provider = data.get('provider', 'onedrive')
    remote_name = data.get('remote_name', 'cloud')

    provider_map = {
        'onedrive': 'onedrive',
        'gdrive': 'drive',
        'dropbox': 'dropbox'
    }
    rclone_type = provider_map.get(provider, provider)

    try:
        result = subprocess.run(
            ['rclone', 'config', 'create', remote_name, rclone_type,
             '--config', RCLONE_CONF],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            return jsonify({'success': True, 'message': f'Remote "{remote_name}" created for {provider}',
                            'output': result.stdout})
        else:
            return jsonify({'success': False, 'error': result.stderr}), 400
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500


@app.route('/api/rclone/authorize', methods=['POST'])
def api_rclone_authorize():
    """API: Get rclone authorize URL."""
    data = request.get_json()
    provider = data.get('provider', 'onedrive')

    provider_map = {
        'onedrive': 'onedrive',
        'gdrive': 'drive',
        'dropbox': 'dropbox'
    }
    rclone_type = provider_map.get(provider, provider)

    try:
        result = subprocess.run(
            ['rclone', 'authorize', rclone_type, '--config', RCLONE_CONF],
            capture_output=True, text=True, timeout=120
        )
        return jsonify({'output': result.stdout + result.stderr})
    except subprocess.TimeoutExpired:
        return jsonify({'error': 'Authorization timed out'}), 408
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/trigger', methods=['POST'])
def api_trigger_backup():
    """API: Trigger a manual backup for an account."""
    data = request.get_json()
    account = data.get('account')
    if not account:
        return jsonify({'error': 'Account name required'}), 400

    trigger_file = os.path.join(DATA_DIR, f'trigger_{account}')
    try:
        with open(trigger_file, 'w') as f:
            f.write(datetime.now().isoformat())
        return jsonify({'success': True, 'message': f'Backup triggered for {account}'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


if __name__ == '__main__':
    port = int(os.environ.get('ADDON_WEB_PORT', 8099))
    app.run(host='0.0.0.0', port=port, debug=False)
