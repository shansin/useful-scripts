import os
import yaml
from datetime import datetime
import logging
import time
import argparse
import asyncio
import aioshutil

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

def load_config(config_path: str):
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

async def sync_folders(source, destination):
    """Recursively copy files that are not present in the destination."""
    if not os.path.exists(destination):
        os.makedirs(destination, exist_ok=True)
    
    new_files_count = 0
    for root, dirs, files in os.walk(source):
        rel_path = os.path.relpath(root, source)
        if rel_path == ".":
            dest_dir = destination
        else:
            dest_dir = os.path.join(destination, rel_path)
        
        if not os.path.exists(dest_dir):
            os.makedirs(dest_dir, exist_ok=True)
            
        for file in files:
            source_file = os.path.join(root, file)
            dest_file = os.path.join(dest_dir, file)
            
            if not os.path.exists(dest_file):
                await aioshutil.copy2(source_file, dest_file)
                new_files_count += 1
    
    if new_files_count > 0:
        logger.info(f"Incremental backup: Copied {new_files_count} new files.")
    else:
        logger.info("Incremental backup: No new files to copy.")

async def perform_backup(task, settings):
    """Run a single backup task asynchronously."""
    source = task.get('source')
    name = task.get('name', os.path.basename(source))
    dest_base = settings.get('destination', './backups')
    backup_type = task.get('type', 'normal')
    ts_format = settings.get('timestamp_format', '%Y%m%d_%H%M%S')
    seven_zip_path = settings.get('seven_zip_path', '7z')
    
    if not os.path.exists(source):
        logger.warning(f"Source directory does not exist: {source}. Skipping task '{name}'.")
        return

    source_dir_name = os.path.basename(os.path.normpath(source))
    
    if backup_type == 'incremental':
        backup_name = f"{name}_{source_dir_name}"
    else:
        timestamp = datetime.now().strftime(ts_format)
        backup_name = f"{name}_{source_dir_name}_{timestamp}"
    
    # Ensure destination directory exists
    if not os.path.exists(dest_base):
        os.makedirs(dest_base, exist_ok=True)
        logger.info(f"Created destination directory: {dest_base}")

    dest_path = os.path.join(dest_base, backup_name)

    logger.info(f"Starting {backup_type} backup for task '{name}'")
    start_time = time.perf_counter()

    try:
        if backup_type == 'zip':
            output_file = f"{dest_path}.7z"
            cmd = [seven_zip_path, "a", output_file, source]
            logger.info(f"Running 7z for task '{name}': {' '.join(cmd)}")
            
            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, stderr = await process.communicate()
            
            if process.returncode == 0:
                logger.info(f"Successfully backed up '{source}' to '{output_file}' using 7-Zip")
            else:
                logger.error(f"7-Zip failed for '{source}': {stderr.decode()}")
        elif backup_type == 'incremental':
            await sync_folders(source, dest_path)
            logger.info(f"Successfully synced '{source}' to '{dest_path}'")
        else: # normal
            await aioshutil.copytree(source, dest_path)
            logger.info(f"Successfully copied '{source}' to '{dest_path}'")
            
        end_time = time.perf_counter()
        logger.info(f"Backup for task '{name}' completed in {(end_time - start_time) / 60:.2f} minutes.")
    except Exception as e:
        logger.error(f"Failed backup for task '{name}': {e}")

async def main():
    parser = argparse.ArgumentParser(description="Directory Backup Utility")
    parser.add_argument("task_name", nargs="?", help="Name of the specific task to run")
    parser.add_argument("config_name", nargs="?", help="Name of the config file to use")
    args = parser.parse_args()

    config_path = args.config_name or "backup_config.yml"

    config = load_config(config_path)
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

    # Prepare list of tasks to run
    tasks_to_run = []
    for task in tasks:
        if not args.task_name and not task.get('run', True):
            logger.info(f"Skipping task '{task.get('name', 'unnamed')}' as 'run' is set to False.")
            continue
        tasks_to_run.append(perform_backup(task, settings))

    if not tasks_to_run:
        logger.info("No tasks to execute.")
        return

    logger.info(f"Starting concurrent backup process for {len(tasks_to_run)} tasks...")
    await asyncio.gather(*tasks_to_run)
    logger.info("Backup process completed.")

if __name__ == "__main__":
    asyncio.run(main())
