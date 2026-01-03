import os
import shutil
import yaml
from datetime import datetime
import logging
import subprocess
import time
import argparse

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

def load_config(config_path='backup_config.yml'):
    """Load configuration from a YAML file."""
    try:
        with open(config_path, 'r') as file:
            return yaml.safe_load(file)
    except FileNotFoundError:
        logger.error(f"Configuration file not found: {config_path}")
        return None
    except yaml.YAMLError as e:
        logger.error(f"Error parsing YAML: {e}")
        return None

def perform_backup(task, settings):
    """Run a single backup task."""
    source = task.get('source')
    name = task.get('name', os.path.basename(source))
    dest_base = settings.get('destination', './backups')
    use_zip = settings.get('zip', False)
    ts_format = settings.get('timestamp_format', '%Y%m%d_%H%M%S')
    seven_zip_path = settings.get('seven_zip_path', '7z')
    
    if not os.path.exists(source):
        logger.warning(f"Source directory does not exist: {source}. Skipping task '{name}'.")
        return

    timestamp = datetime.now().strftime(ts_format)
    source_dir_name = os.path.basename(os.path.normpath(source))
    backup_name = f"{name}_{source_dir_name}_{timestamp}"
    
    # Ensure destination directory exists
    if not os.path.exists(dest_base):
        os.makedirs(dest_base)
        logger.info(f"Created destination directory: {dest_base}")

    dest_path = os.path.join(dest_base, backup_name)

    if use_zip:
        try:
            # -t7z for 7z format, or -tzip for zip. Prompt said "replace shutils" for speed.
            # We'll use .7z for maximum efficiency or stick to .zip if preferred.
            # Let's use 7z format as it's typically faster/better with 7-Zip.
            output_file = f"{dest_path}.7z"
            cmd = [seven_zip_path, "a", output_file, source]
            logger.info(f"Running 7z: {' '.join(cmd)}")
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode == 0:
                logger.info(f"Successfully backed up '{source}' to '{output_file}' using 7-Zip")
            else:
                logger.error(f"7-Zip failed for '{source}': {result.stderr}")
        except Exception as e:
            logger.error(f"Failed to run 7-Zip for '{source}': {e}")
    else:
        try:
            shutil.copytree(source, dest_path)
            logger.info(f"Successfully copied '{source}' to '{dest_path}'")
        except Exception as e:
            logger.error(f"Failed to copy '{source}': {e}")

def main():
    parser = argparse.ArgumentParser(description="Directory Backup Utility")
    parser.add_argument("task_name", nargs="?", help="Name of the specific task to run")
    args = parser.parse_args()

    config = load_config()
    if not config:
        return

    settings = config.get('backup_settings', {})
    tasks = config.get('tasks', [])

    if not tasks:
        logger.warning("No backup tasks found in configuration.")
        return

    # If a specific task is named, filter for it
    if args.task_name:
        tasks = [t for t in tasks if t.get('name') == args.task_name]
        if not tasks:
            logger.error(f"No task found with name '{args.task_name}'")
            return
        logger.info(f"Task override: Running only '{args.task_name}' (ignoring 'run' status)")

    logger.info(f"Starting backup process for {len(tasks)} tasks...")
    for task in tasks:
        # Only check 'run' status if we are NOT targeting a specific task
        if not args.task_name and not task.get('run', True):
            logger.info(f"Skipping task '{task.get('name', 'unnamed')}' as 'run' is set to False.")
            continue
            
        logger.info(f"Starting backup for task '{task.get('name', 'unnamed')}'")
        start_time = time.perf_counter()
        perform_backup(task, settings)
        end_time = time.perf_counter()
        logger.info(f"Backup for task '{task.get('name', 'unnamed')}' completed in {(end_time - start_time) / 60:.2f} minutes.")
    logger.info("Backup process completed.")

if __name__ == "__main__":
    main()
