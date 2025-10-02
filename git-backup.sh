#!/bin/bash

#===========================================
# CONFIGURATION - Edit these variables
#===========================================

# Set to true/false to enable/disable cloning
CLONE_ORGS=true
CLONE_PERSONAL=true

# Define multiple organizations
ORGS=("ORG_1" "ORG_1" "ORG_3")

# Define username for personal repos
USERNAME="USERNAME"

# GitHub token for private repos and higher rate limits
# Generate a token at https://github.com/settings/personal-access-tokens/new
GITHUB_TOKEN="GITHUB_TOKEN"

# Enable debug mode to see API responses
DEBUG=true

# Validate that token is set
if [ -z "$GITHUB_TOKEN" ] || [ "$GITHUB_TOKEN" = "your_token_here" ]; then
    echo "ERROR: GitHub token is required!"
    echo "Please set GITHUB_TOKEN in the script or as an environment variable."
    echo ""
    echo "To get a GitHub token:"
    echo "1. Go to GitHub.com → Settings → Developer settings → Personal access tokens"
    echo "2. Click 'Tokens (classic)' → 'Generate new token (classic)'"
    echo "3. Select 'repo' and 'read:org' permissions"
    echo "4. Set GITHUB_TOKEN=\"your_token_here\" in this script"
    echo ""
    exit 1
fi

# Create dated folder
DATE_FOLDER=$(date +%Y-%m-%d)
echo "Creating workspace folder: $DATE_FOLDER"
mkdir -p "$DATE_FOLDER"
cd "$DATE_FOLDER"

#===========================================
# FUNCTIONS
#===========================================

# Function to make authenticated API calls
make_api_call() {
    local url=$1
    local response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$url")
    
    # Debug: Show API response if debug is enabled
    if [ "$DEBUG" = true ]; then
        echo "DEBUG: API URL: $url" >&2
        echo "DEBUG: Response: ${response:0:200}..." >&2 # Show first 200 chars
    fi
    
    # Check for API errors
    if echo "$response" | grep -q '"message".*"API rate limit exceeded"'; then
        echo "ERROR: GitHub API rate limit exceeded. Please wait and try again."
        exit 1
    elif echo "$response" | grep -q '"message".*"Bad credentials"'; then
        echo "ERROR: Invalid GitHub token. Please check your GITHUB_TOKEN."
        exit 1
    elif echo "$response" | grep -q '"message".*"forbids access via a fine-grained personal access tokens"'; then
        echo "ERROR: GitHub token is too old (greater than 366 days)."
        echo "The organization requires a token with a lifetime of 366 days or less."
        echo "Please create a new token at: https://github.com/settings/personal-access-tokens"
        echo "Set the expiration to 366 days or less."
        exit 1
    elif echo "$response" | grep -q '"status".*"403"'; then
        echo "ERROR: Access forbidden (403). This could be due to:"
        echo "1. Token doesn't have sufficient permissions"
        echo "2. Token is too old for this organization"
        echo "3. Organization has restricted access policies"
        echo "Response: ${response:0:200}..."
        exit 1
    fi
    
    echo "$response"
}

# Function to clone all repos for a single organization
clone_org_repos() {
    local org=$1
    echo "Cloning repositories for organization: $org"
    
    # Create directory for the organization (directly in dated folder)
    mkdir -p "$org"
    cd "$org"
    
    local page=1
    local per_page=100
    local total_repos_found=0
    
    while true; do
        echo "Fetching page $page for $org..."
        local api_url="https://api.github.com/orgs/$org/repos?type=all&per_page=$per_page&page=$page"
        
        # Get response from API
        local response=$(make_api_call "$api_url")
        
        # Debug: Show raw API response
        if [ "$DEBUG" = true ]; then
            echo "DEBUG: Raw API response:" >&2
            # echo "$response" >&2
        fi
        
        # Check if organization exists
        if echo "$response" | grep -q '"message".*"Not Found"'; then
            echo "ERROR: Organization '$org' not found or not accessible."
            cd ..
            return 1
        fi
        
        # Check if response is empty array
        if [ "$response" = "[]" ]; then
            echo "Empty response - no repositories found for $org"
            break
        fi
        
        # Extract SSH URLs and clone URLs using jq
        local ssh_repos=""
        local clone_repos=""
        # Try to extract URLs with jq, handle errors gracefully
        if echo "$response" | jq -e '.' >/dev/null 2>&1; then
            # Check if it's an array and has elements
            local array_length=$(echo "$response" | jq -r 'length // 0')
            if [ "$array_length" -gt 0 ]; then
                ssh_repos=$(echo "$response" | jq -r '.[].ssh_url // empty')
                clone_repos=$(echo "$response" | jq -r '.[].clone_url // empty')
            else
                echo "DEBUG: JSON array is empty" >&2
            fi
        else
            echo "DEBUG: jq failed to parse response as valid JSON" >&2
            echo "DEBUG: First 200 chars of response: '${response:0:200}'" >&2
            echo "DEBUG: Last 200 chars of response: '${response: -200}'" >&2
        fi
        
        # Debug: Show raw extraction results
        if [ "$DEBUG" = true ]; then
            echo "DEBUG: Raw SSH jq result:" >&2
            echo "$ssh_repos" >&2
            echo "DEBUG: Raw clone jq result:" >&2
            echo "$clone_repos" >&2
        fi
        
        # Debug: Show what we found
        if [ "$DEBUG" = true ]; then
            if [ -n "$ssh_repos" ]; then
                echo "DEBUG: SSH URLs found: $(echo "$ssh_repos" | grep -c .)" >&2
                echo "DEBUG: First SSH URL: $(echo "$ssh_repos" | head -1)" >&2
            else
                echo "DEBUG: SSH URLs found: 0" >&2
            fi
            if [ -n "$clone_repos" ]; then
                echo "DEBUG: Clone URLs found: $(echo "$clone_repos" | grep -c .)" >&2
                echo "DEBUG: First Clone URL: $(echo "$clone_repos" | head -1)" >&2
            else
                echo "DEBUG: Clone URLs found: 0" >&2
            fi
        fi
        
        # Extract archived status and repository info
        local repo_info=""
        if echo "$response" | jq -e '.' >/dev/null 2>&1; then
            repo_info=$(echo "$response" | jq -r '.[] | "\(.clone_url // .ssh_url)|\(.archived)|\(.name)"')
        fi
        
        # If no repos found, we've reached the end
        if [ -z "$repo_info" ]; then
            echo "No more repositories found for $org on page $page"
            break
        fi
        
        # Print the first 500 chars of the API response for debugging
        if [ "$DEBUG" = true ]; then
            echo "DEBUG: API response (first 500 chars):" >&2
            echo "${response:0:500}" >&2
        fi
        
        # Clone each repository
        while IFS='|' read -r repo_url is_archived repo_name; do
            if [ "$DEBUG" = true ]; then
                echo "DEBUG: Processing $repo_name - URL: $repo_url, Archived: $is_archived" >&2
            fi
            if [ -n "$repo_url" ] && [ "$repo_url" != "null" ]; then
                # Use token authentication for HTTPS URLs
                if [[ "$repo_url" == https://github.com/* ]]; then
                    repo_url=$(echo "$repo_url" | sed "s|https://github.com/|https://$GITHUB_TOKEN@github.com/|")
                fi
                
                # Determine target directory based on archived status
                local target_dir=""
                if [ "$is_archived" = "true" ]; then
                    target_dir="archive"
                    mkdir -p "$target_dir"
                    echo "📦 Repository $repo_name is archived - placing in archive folder"
                else
                    target_dir="."
                fi
                
                if [ ! -d "$target_dir/$repo_name" ]; then
                    echo "Cloning: $repo_url"
                    if git clone "$repo_url" "$target_dir/$repo_name"; then
                        echo "Successfully cloned $repo_name to $target_dir/"
                        ((total_repos_found++))
                    else
                        echo "Failed to clone $repo_name"
                    fi
                else
                    echo "Repository $repo_name already exists in $target_dir/, skipping..."
                fi
            fi
        done <<< "$repo_info"
        
        # Count repos on this page
        local repo_count=$(echo "$repo_info" | grep -c .)
        echo "Found $repo_count repositories on page $page"
        
        # Check if we got fewer repos than per_page (last page)
        if [ "$repo_count" -lt "$per_page" ]; then
            echo "Reached last page for $org"
            break
        fi
        
        ((page++))
    done
    
    cd ..
    
    # Count actual directories created
    local actual_count=$(find "$org" -maxdepth 1 -type d | wc -l)
    echo "Finished cloning repositories for $org - Total directories: $((actual_count - 1))"
    echo "----------------------------------------"
}

# Function to clone all personal repos for a user
clone_personal_repos() {
    local username=$1
    echo "Cloning personal repositories for user: $username"
    
    # Create directory for personal repos (directly in dated folder)
    mkdir -p "$username"
    cd "$username"
    
    local page=1
    local per_page=100
    
    while true; do
        echo "Fetching page $page for personal repos of $username..."
        local api_url="https://api.github.com/users/$username/repos?type=owner&visibility=all&per_page=$per_page&page=$page"
        
        # Get response from API
        local response=$(make_api_call "$api_url")
        
        # Debug: Show raw API response
        if [ "$DEBUG" = true ]; then
            echo "DEBUG: Raw API response (first 1000 chars):" >&2
            echo "${response:0:1000}" >&2
        fi
        
        # Check if user exists
        if echo "$response" | grep -q '"message".*"Not Found"'; then
            echo "ERROR: User '$username' not found."
            cd ..
            return 1
        fi
        
        # Check if response is empty array
        if [ "$response" = "[]" ]; then
            echo "Empty response - no repositories found for $username"
            break
        fi
        
        # Extract SSH URLs and clone URLs using jq
        local ssh_repos=""
        local clone_repos=""
        # Try to extract URLs with jq, handle errors gracefully
        if echo "$response" | jq -e '.' >/dev/null 2>&1; then
            # Check if it's an array and has elements
            local array_length=$(echo "$response" | jq -r 'length // 0')
            if [ "$array_length" -gt 0 ]; then
                ssh_repos=$(echo "$response" | jq -r '.[].ssh_url // empty')
                clone_repos=$(echo "$response" | jq -r '.[].clone_url // empty')
            else
                echo "DEBUG: JSON array is empty" >&2
            fi
        else
            echo "DEBUG: jq failed to parse response as valid JSON" >&2
            echo "DEBUG: First 200 chars of response: '${response:0:200}'" >&2
            echo "DEBUG: Last 200 chars of response: '${response: -200}'" >&2
        fi
        
        # Debug: Show raw extraction results
        if [ "$DEBUG" = true ]; then
            echo "DEBUG: Raw SSH jq result:" >&2
            echo "$ssh_repos" >&2
            echo "DEBUG: Raw clone jq result:" >&2
            echo "$clone_repos" >&2
            # Debug: Show what we found
            if [ -n "$ssh_repos" ]; then
                echo "DEBUG: SSH URLs found: $(echo "$ssh_repos" | grep -c .)" >&2
                echo "DEBUG: First SSH URL: $(echo "$ssh_repos" | head -1)" >&2
            else
                echo "DEBUG: SSH URLs found: 0" >&2
            fi
            if [ -n "$clone_repos" ]; then
                echo "DEBUG: Clone URLs found: $(echo "$clone_repos" | grep -c .)" >&2
                echo "DEBUG: First Clone URL: $(echo "$clone_repos" | head -1)" >&2
            else
                echo "DEBUG: Clone URLs found: 0" >&2
            fi
        fi
        
        # Extract archived status and repository info
        local repo_info=""
        if echo "$response" | jq -e '.' >/dev/null 2>&1; then
            repo_info=$(echo "$response" | jq -r '.[] | "\(.clone_url // .ssh_url)|\(.archived)|\(.name)"')
        fi
        
        # If no repos found, we've reached the end
        if [ -z "$repo_info" ]; then
            echo "No more personal repositories found for $username"
            break
        fi
        
        # Clone each repository
        while IFS='|' read -r repo_url is_archived repo_name; do
            if [ "$DEBUG" = true ]; then
                echo "DEBUG: Processing $repo_name - URL: $repo_url, Archived: $is_archived" >&2
            fi
            if [ -n "$repo_url" ] && [ "$repo_url" != "null" ]; then
                # Use token authentication for HTTPS URLs
                if [[ "$repo_url" == https://github.com/* ]]; then
                    repo_url=$(echo "$repo_url" | sed "s|https://github.com/|https://$GITHUB_TOKEN@github.com/|")
                fi
                
                # Determine target directory based on archived status
                local target_dir=""
                if [ "$is_archived" = "true" ]; then
                    target_dir="archive"
                    mkdir -p "$target_dir"
                    echo "📦 Repository $repo_name is archived - placing in archive folder"
                else
                    target_dir="."
                fi
                
                if [ ! -d "$target_dir/$repo_name" ]; then
                    echo "Cloning: $repo_url"
                    if git clone "$repo_url" "$target_dir/$repo_name"; then
                        echo "Successfully cloned $repo_name to $target_dir/"
                    else
                        echo "Failed to clone $repo_name"
                    fi
                else
                    echo "Repository $repo_name already exists in $target_dir/, skipping..."
                fi
            fi
        done <<< "$repo_info"
        
        # Count repos on this page
        local repo_count=$(echo "$repo_info" | grep -c .)
        echo "Found $repo_count repositories on page $page"
        
        # Check if we got fewer repos than per_page (last page)
        if [ "$repo_count" -lt "$per_page" ]; then
            echo "Reached last page for personal repos of $username"
            break
        fi
        
        ((page++))
    done
    
    cd ..
    echo "Finished cloning personal repositories for $username"
    echo "----------------------------------------"
}

# Function to create summary and zip everything
finalize_backup() {
    echo "Creating backup summary..."
    
    # Create a summary file
    cat > "BACKUP_SUMMARY.txt" << EOF
GitHub Repository Backup
========================
Date: $(date)
Backup folder: $DATE_FOLDER

Folders created:
EOF
    
    # List organization folders
    if [ "$CLONE_ORGS" = true ] && [ ${#ORGS[@]} -gt 0 ]; then
        echo "" >> "BACKUP_SUMMARY.txt"
        echo "Organization folders:" >> "BACKUP_SUMMARY.txt"
        for org in "${ORGS[@]}"; do
            if [ -n "$org" ] && [ -d "$org" ]; then
                echo "- $org/" >> "BACKUP_SUMMARY.txt"
                
                # Count active repositories (not in archive folder)
                local active_count=$(find "$org" -maxdepth 1 -type d ! -path "$org" ! -path "$org/archive" | wc -l)
                echo "  Active repositories: $active_count" >> "BACKUP_SUMMARY.txt"
                
                # Count archived repositories
                local archived_count=0
                if [ -d "$org/archive" ]; then
                    archived_count=$(find "$org/archive" -maxdepth 1 -type d ! -path "$org/archive" | wc -l)
                fi
                echo "  Archived repositories: $archived_count" >> "BACKUP_SUMMARY.txt"
                echo "  Total repositories: $((active_count + archived_count))" >> "BACKUP_SUMMARY.txt"
                
                # List active repositories
                if [ $active_count -gt 0 ]; then
                    echo "  Active repository names:" >> "BACKUP_SUMMARY.txt"
                    find "$org" -maxdepth 1 -type d ! -path "$org" ! -path "$org/archive" -exec basename {} \; | while read repo; do
                        echo "    - $repo" >> "BACKUP_SUMMARY.txt"
                    done
                fi
                
                # List archived repositories
                if [ $archived_count -gt 0 ]; then
                    echo "  Archived repository names:" >> "BACKUP_SUMMARY.txt"
                    find "$org/archive" -maxdepth 1 -type d ! -path "$org/archive" -exec basename {} \; | while read repo; do
                        echo "    - $repo (archived)" >> "BACKUP_SUMMARY.txt"
                    done
                fi
            fi
        done
    fi
    
    # List personal folder
    if [ "$CLONE_PERSONAL" = true ] && [ -n "$USERNAME" ] && [ -d "$USERNAME" ]; then
        echo "" >> "BACKUP_SUMMARY.txt"
        echo "Personal folder:" >> "BACKUP_SUMMARY.txt"
        echo "- $USERNAME/" >> "BACKUP_SUMMARY.txt"
        
        # Count active repositories (not in archive folder)
        local active_count=$(find "$USERNAME" -maxdepth 1 -type d ! -path "$USERNAME" ! -path "$USERNAME/archive" | wc -l)
        echo "  Active repositories: $active_count" >> "BACKUP_SUMMARY.txt"
        
        # Count archived repositories
        local archived_count=0
        if [ -d "$USERNAME/archive" ]; then
            archived_count=$(find "$USERNAME/archive" -maxdepth 1 -type d ! -path "$USERNAME/archive" | wc -l)
        fi
        echo "  Archived repositories: $archived_count" >> "BACKUP_SUMMARY.txt"
        echo "  Total repositories: $((active_count + archived_count))" >> "BACKUP_SUMMARY.txt"
        
        # List active repositories
        if [ $active_count -gt 0 ]; then
            echo "  Active repository names:" >> "BACKUP_SUMMARY.txt"
            find "$USERNAME" -maxdepth 1 -type d ! -path "$USERNAME" ! -path "$USERNAME/archive" -exec basename {} \; | while read repo; do
                echo "    - $repo" >> "BACKUP_SUMMARY.txt"
            done
        fi
        
        # List archived repositories
        if [ $archived_count -gt 0 ]; then
            echo "  Archived repository names:" >> "BACKUP_SUMMARY.txt"
            find "$USERNAME/archive" -maxdepth 1 -type d ! -path "$USERNAME/archive" -exec basename {} \; | while read repo; do
                echo "    - $repo (archived)" >> "BACKUP_SUMMARY.txt"
            done
        fi
    fi
    
    echo "" >> "BACKUP_SUMMARY.txt"
    echo "All folders in backup:" >> "BACKUP_SUMMARY.txt"
    for folder in */; do
        # Skip personal folder if CLONE_PERSONAL is false
        if [ "$CLONE_PERSONAL" != true ] && [ "$folder" = "$USERNAME/" ]; then
            continue
        fi
        if [ "$folder" != "./" ]; then
            echo "- $folder" >> "BACKUP_SUMMARY.txt"
        fi
    done
    
    echo "" >> "BACKUP_SUMMARY.txt"
    echo "Total disk usage:" >> "BACKUP_SUMMARY.txt"
    du -sh . >> "BACKUP_SUMMARY.txt"
    
    echo "Backup summary created."
    
    # Move back to parent directory for zipping
    cd ..
    
    echo "Creating zip archive: ${DATE_FOLDER}.zip"
    
    # Check if zip command exists
    if command -v zip &> /dev/null; then
        # Use zip command (excludes .git folders to save space)
        if [ "$CLONE_PERSONAL" = true ] || [ ! -d "$DATE_FOLDER/$USERNAME" ]; then
            zip -r "${DATE_FOLDER}.zip" "$DATE_FOLDER" -x "*.git/*" "*.git*"
        else
            zip -r "${DATE_FOLDER}.zip" "$DATE_FOLDER" -x "*.git/*" "*.git*" "$DATE_FOLDER/$USERNAME/*" "$DATE_FOLDER/$USERNAME"
        fi
        echo "Zip archive created successfully: ${DATE_FOLDER}.zip"
    elif command -v tar &> /dev/null; then
        # Fallback to tar if zip is not available
        echo "zip command not found, using tar instead..."
        if [ "$CLONE_PERSONAL" = true ] || [ ! -d "$DATE_FOLDER/$USERNAME" ]; then
            tar -czf "${DATE_FOLDER}.tar.gz" "$DATE_FOLDER" --exclude='.git'
        else
            tar -czf "${DATE_FOLDER}.tar.gz" "$DATE_FOLDER" --exclude='.git' --exclude="$DATE_FOLDER/$USERNAME"
        fi
        echo "Tar archive created successfully: ${DATE_FOLDER}.tar.gz"
    else
        echo "Neither zip nor tar found. Archive not created."
        echo "You can manually compress the folder: $DATE_FOLDER"
    fi
    
    # Show final summary
    echo ""
    echo "============================================"
    echo "BACKUP COMPLETED!"
    echo "============================================"
    echo "Date: $(date)"
    echo "Folder: $DATE_FOLDER"
    if [ -f "${DATE_FOLDER}.zip" ]; then
        echo "Archive: ${DATE_FOLDER}.zip"
        echo "Archive size: $(du -sh "${DATE_FOLDER}.zip" | cut -f1)"
    elif [ -f "${DATE_FOLDER}.tar.gz" ]; then
        echo "Archive: ${DATE_FOLDER}.tar.gz"
        echo "Archive size: $(du -sh "${DATE_FOLDER}.tar.gz" | cut -f1)"
    fi
    echo "Folder size: $(du -sh "$DATE_FOLDER" | cut -f1)"
    echo ""
    echo "Directory structure:"
    echo "$DATE_FOLDER/"
    for folder in "$DATE_FOLDER"/*/; do
        if [ -d "$folder" ]; then
            folder_name=$(basename "$folder")
            echo "├── $folder_name/"
            
            # Show first few active repos as example
            local count=0
            for repo in "$folder"*/; do
                if [ -d "$repo" ] && [ $count -lt 3 ] && [ "$(basename "$repo")" != "archive" ]; then
                    repo_name=$(basename "$repo")
                    echo "│   ├── $repo_name/"
                    ((count++))
                fi
            done
            local active_repos=$(find "$folder" -maxdepth 1 -type d ! -path "$folder" ! -path "$folder/archive" | wc -l)
            if [ $active_repos -gt 3 ]; then
                echo "│   ├── ... ($((active_repos - 3)) more active repositories)"
            fi
            
            # Show archive folder if it exists
            if [ -d "$folder/archive" ]; then
                local archived_repos=$(find "$folder/archive" -maxdepth 1 -type d ! -path "$folder/archive" | wc -l)
                echo "│   └── archive/ ($archived_repos archived repositories)"
            fi
        fi
    done
    echo "============================================"
}

#===========================================
# MAIN EXECUTION
#===========================================

echo "Starting GitHub repository backup for $(date +%Y-%m-%d)..."
echo "Working directory: $(pwd)/$DATE_FOLDER"
echo "Using GitHub token: ${GITHUB_TOKEN:0:8}..." # Show first 8 characters only
echo ""

# Clone organization repositories
if [ "$CLONE_ORGS" = true ] && [ ${#ORGS[@]} -gt 0 ]; then
    echo "Processing organization repositories..."
    for org in "${ORGS[@]}"; do
        if [ -n "$org" ]; then
            clone_org_repos "$org"
        fi
    done
else
    echo "Organization cloning disabled or no organizations specified."
fi

# Clone personal repositories
if [ "$CLONE_PERSONAL" = true ] && [ -n "$USERNAME" ]; then
    echo "Processing personal repositories..."
    clone_personal_repos "$USERNAME"
else
    echo "Personal repository cloning disabled or no username specified."
fi

# Finalize the backup
finalize_backup
