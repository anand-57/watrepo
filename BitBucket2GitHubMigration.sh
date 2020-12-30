#!/bin/bash

#############################################
##### function to display utility usage #####
#############################################
function usage()
{
    echo -e "$blue"
    echo -e "##########################################################"
    echo -e "  Usage: "
    echo -e "    $0"
    echo -e "    --repo-file=<repository_file> --team=<GitHub_Team>"
    echo -e "##########################################################"
    echo -e "$reset"
    exit 0
}

###################################
##### function to exit script #####
###################################
function exitWrapper()
{
    local message=$1
    echo -e "$red"
    [ -z "$message" ] && message="Exited"
    echo -e "[\xE2\x9C\x95] $message at ${BASH_SOURCE[1]}:${FUNCNAME[1]} line ${BASH_LINENO[0]}." >&2
    [ "${FUNCNAME[1]}" != "main" ] && echo -e "[\xE2\x9C\x95] BitBucket to GitHub migration for repository <$repository> failed, exiting..." 
    echo -e "$reset"
    exit 1
}

###################################################
##### function to validate open pull requests #####
###################################################
function checkBitBucketOpenPullRequest()
{
    repoExist=$(curl -s -n "$BitBucketApiURL/$repository" | grep -c "NoSuchRepositoryException")
    [ "$repoExist" -gt 0 ] && exitWrapper "Bitbucket repository <$repository> does not exist, exiting..."
    echo -e "${green}==> checking open pull-requests in BitBucket repository <$repository> prior to proceeding with migration, please wait...${reset}" 
    totalOpenPullRequests=$(curl -s -n "$BitBucketApiURL/$repository/pull-requests?state=OPEN" | python -m json.tool | grep -c '"state": "OPEN"')
    totalOpenPullRequests=$(echo "$totalOpenPullRequests" | xargs echo -n) 
    if [ "$totalOpenPullRequests" -gt 0 ]; then
       echo -e "$blue"
       echo -e "BitBucket repository <$repository> have $totalOpenPullRequests open pull requests"
       echo -e "Please close all open pull requuests prior to proceed with migration"
       echo -e "$reset"
       exit 0
    fi
    echo -e "${cyan}\xE2\x9C\x94 BitBucket repository <$repository> does not have open pull-requests, good to proceed with migration${reset}"
    
}

#########################################
##### function to fetch the team id #####
#########################################
function getGitHubTeamID()
{
    echo -e "${green}==> fetching GitHub team id, please wait...${reset}"
    cmd=$(curl -n -s -H 'Accepts:application/vnd.github.v3+jso' "$GitHubApiURL/orgs/$GitHubOrganization/teams/$GitHubTeam" || exitWrapper "failed to fetch GitHub teams, exiting...")
    GitHubTeamID=$(echo "$cmd" | grep -A1 "\"name\": \"$GitHubTeam\"" | grep '"id":' | sed 's/^ *"id": \(.*\),/\1/g')
    [ -z "$GitHubTeamID" ] && exitWrapper "failed to get GitHub Team ID, exiting..."
    echo -e "${cyan}\xE2\x9C\x94 GitHub Team $GitHubTeam having Team ID: $GitHubTeamID${reset}"
}

################################################
##### function to create GitHub repository #####
################################################
function createGitHubRepository()
{
    echo -e "${green}==> checking GitHub repository <$repository>, please wait...${reset}"
    git ls-remote --exit-code "$GitHubURL/$repository" &> /dev/null
    if [ $? ]; then
       echo -e "${green}==> creating GitHub repository $repository, please wait...${reset}"
       curl -s -n "$GitHubApiURL/user/repos" -d "{\"name\":\"$repository\", \"private\": \"false\", \"internal\":\"true\"}" || exitWrapper "failed to create GitHub repository $repository, exiting"
       echo -e "${cyan}\xE2\x9C\x94 GitHub repository $repository created successfully...${reset}"
    else
       echo -e "${green}==> GitHub repository $repository already exist...${reset}"
       echo -e "$green"
       read -p "Would You Like to Proceed With Existing GitHub Repository [Yes/No]: " option
       echo -e "$reset"
       option=$(echo "$option" | awk '{print tolower($0)}')
       [ "$option" != "yes" ] && exitWrapper "You decided not to proceed further with migration, exiting..."
    fi
}

###############################################
##### function to perform BitBucket tasks #####
###############################################
function bitBucketRepositoryTasks()
{
    cd "$BitBucketDirectory" || exitWrapper "failed to switch to directory $BitBucketDirectory, exiting..."
    git clone --mirror "$BitBucketURL/$repository" . || exitWrapper "failed to clone BitBucket repository $repository, exiting..."
    if git rev-parse --verify --quiet master; then
       if git rev-parse --quiet --verify main; then
          exitWrapper "main branch already exist in repository $repository, exiting..."
       fi
       echo -e "${green}==> renaming <master> branch to <main>${reset}"
       git branch -m master main || exitWrapper "failed to rename <master> branch to <main> branch, exiting..."
       echo -e "${cyan}\xE2\x9C\x94 master branch renamed to main branch successfully${reset}"
    fi
}

##########################################
##### function to validate migration #####
##########################################
function validateMigration()
{
    for type in "BitBucket" "GitHub"; do
      echo -e "${green}==> fetching branches, tags and commit details from $type repository, please wait...${reset}"
      [ "$type" == "BitBucket" ] && CodeDirectory="$BitBucketDirectory"
      [ "$type" == "GitHub" ] && CodeDirectory="$GitHubDirectory"
      ValidationFile="$ValidationDirectory/${type}.txt"
      cd "$CodeDirectory" || exitWrapper "failed to switch to $CodeDirectory, exiting..."
      echo -e "repository:$repository\n" > "$ValidationFile"
      branches=$(git branch --list | tr -d '^ ')
      if [ -n "$branches" ]; then
         echo "branches:" >> "$ValidationFile"
         for branch in $branches; do 
            echo "$branch" >> "$ValidationFile"
         done
      fi 
      echo -e "\n" >> "$ValidationFile"
      tags=$(git tag --list)
      if [ -n "$tags" ]; then 
         echo -e "tags:" >> "$ValidationFile"
         for tag in $tags; do 
            echo "$tag" >> "$ValidationFile"
         done
      fi
      {
        echo -e "\n" 
        echo -e "commit details:" 
      } >> "$ValidationFile"
      git log --oneline | nl -v0 | sed 's/^ \+/&HEAD~/' | awk '{$1=$1};1' >> "$ValidationFile"
    done
    [[ -n $(diff "$ValidationDirectory/BitBucket.txt" "$ValidationDirectory/GitHub.txt") ]] && exitWrapper "issue seems be in migration, exiting..."
    echo -e "$cyan\xE2\x9C\x94 Migration validation successfully done$reset\n"
}

######################################################
##### function to push GitHub workflow templates #####
######################################################
function pushGitHubWorkflowTemplates()
{
    if [ ! -d "$GitHubWorkflowTemplateDirectory" ]; then 
       echo "GitHub workflow template directory $GitHubWorkflowTemplateDirectory does not exist, nothing to copy"
    else
       if [ "$(ls -A "$GitHubWorkflowTemplateDirectory")" ]; then
          mkdir -p "$GitHubCloneDirectory" || exitWrapper "failed to create clone directory $GitHubCloneDirectory, exiting..."
          git clone "$GitHubURL/$GitHubRepository" "$GitHubCloneDirectory" || exitWrapper "failed to clone GitHub repository $GitHubRepository, exiting..."
          echo -e "${green}==> copying GitHub workflow template files, please wait...${reset}"
          cp -rpa "$GitHubWorkflowTemplateDirectory"/. "$GitHubCloneDirectory" || exitWrapper "failed to copy GitHub workflow template directory $GitHubWorkflowTemplateDirectory files, exiting..."
          cd "$GitHubCloneDirectory" || exitWrapper "failed to switch to directory $GitHubCloneDirectory, exiting..."
          git add -A :/ || exitWrapper "failed to add GitHub workflow template contents, exiting..."
          git commit -am "Added GitHub workflow template contents" || xitWrapper "failed to commit GitHub workflow template contents, exiting..."
          echo -e "${cyan}\xE2\x9C\x94 GitHub workflow templates successfully added${reset}"
          echo -e "${green}==> pushing GitHub workflow templates to GitHub repositoty${reset}"
          git push || exitWrapper "failed to push GitHub workflow templates to GitHub repositoty, exiting..."
          echo -e "$cyan\xE2\x9C\x94 GitHub workflow templates successfully pushed to GitHub repositoty${reset}"
       fi
    fi  
}

############################################
##### function to perform GitHub Tasks #####
############################################
function gitHubRepositoryTasks()
{
    cd "$BitBucketDirectory" || exitWrapper "failed to switch to directory $BitBucketDirectory, exiting..."
    echo -e "${green}==> pushing BitBucket repository $repository to GitHub repository $GitHubRepository${reset}"
    git remote set-url --push origin "$GitHubURL/$GitHubRepository" || exitWrapper "failed to set-url for GitHub repository, exiting..."
    git push --mirror || exitWrapper "failed to push BitBucket repository $repository to GitHub repository $GitHubRepository, exiting..."
    echo -e "${cyan}\xE2\x9C\x94 BitBucket repository <$repository> pushed to GitHub repository <$GitHubRepository> successfully${reset}"
}

###############################################
##### function to clone GitHub repository #####
###############################################
function cloneGitHubRepository()
{
    echo "==> cloning GitHub repository $GitHubRepository with --mirror switch, please wait..."
    cd "$GitHubDirectory" || exitWrapper "failed to switch to directory $GitHubDirectory, exiting..."
    git clone --mirror "$GitHubURL/$GitHubRepository" . || exitWrapper "failed to clone GitHub repository $GitHubRepository, exiting..."
    echo -e "${cyan}\xE2\x9C\x94 GitHub repository $GitHubRepository with --mirror switch is cloned successfully${reset}"
}

###########################################
##### function to call python wrapper #####
###########################################
function runPythonWrapper()
{
   echo -e "${green}==> initiating python wrapper to create GitHub repository and to apply policies, please wait..."
   export PYTHONIOENCODING=UTF-8
   pip install --ignore-installed -r requirements.txt || exitWrapper "failed to install all required python packages, exiting..."
   python -c "from main import migration;migration(\"$GitHubRepository\",$GitHubTeamID,'true',\"$RepoDescription\",'true');"
   echo -e "${cyan}\xE2\x9C\x94 python wrapper executed successfully${reset}"
}

###########################################
##### function to protect main branch #####
###########################################
function protectMainBranch()
{
    echo -e "${green}==> applying protection on branch $gitBranch in GitHub repository $GitHubRepository, please wait...${reset}"
    curl -X PUT -n -H "Accept: application/vnd.github.luke-cage-preview+json" "$GitHubApiURL/repos/$GitHubOrganization/$GitHubRepository/branches/$gitBranch/protection" -d '{"required_status_checks":{"strict":true,"contexts":["contexts"]},"enforce_admins":true,"required_pull_request_reviews":{"dismissal_restrictions":{"users":[],"teams":["sre"]},"require_code_owner_reviews":true,"required_approving_review_count":2},"restrictions":null,"allow_deletions": false}' || exitWrapper "failed to set protection on main branch, exiting..."
    echo -e "${cyan}\xE2\x9C\x94 branch protection on branch $gitBranch in GitHub repository $GitHubRepository successfully applied${reset}"
}

clear
green='\033[0;32m'
blue='\033[0;33m'
cyan='\033[0;36m'
red='\033[0;31m'
reset='\033[0m'

for i in "$@"; do
case $i in
  --empty)
      isEmpty=true
      shift
      ;;
  --backend)
      isBackend=true
      shift
      ;;
  --repo-file=*)
      repoFile="${i#*=}"
      shift
      ;;
  --team=*)
      GitHubTeam="${i#*=}"
      shift
      ;;
  --help)
      usage
      ;;
  *)
      exitWrapper "Please pass supported options, exiting..."
      ;;
esac
done

[ -z "$GitHubTeam" ] && exitWrapper "pass GitHub Team name with --team=<GitHub_Team>, exiting..."
[ -z "$repoFile" ] && exitWrapper "pass repository file with --repo-file switch, exiting..."
[ -z "$isEmpty" ] && isEmpty=false
[ -z "$isBackend" ] && isBackend=false
[ ! -s "$repoFile" ] && exitWrapper "$repoFile does not exist or empty..."

rootDirectory="$HOME/BitBucket2GitHubMigration"
GitHubOrganization="anand-57"
gitBranch="main"
GitHubApiURL="https://api.github.com"
BitBucketURL="https://bitbucket.org/anandasr123/waters2/src/master/"
GitHubURL="https://github.com/$GitHubOrganization"

RepoDescription="initial BitBucket to GitHub migration"
GitHubTeamID=""
[ -z "$BitBucketURL" ] && exitWrapper "pass BitBucket hosting url with --bitbucket-url=<bitbucket_url>, exiting..."
[ -z "$GitHubURL" ] && exitWrapper "pass GitHub hosting url with --github-url=<github_url>, exiting..."
RepoRootDirectory=$(pwd)
GitHubWorkflowTemplateDirectory="$RepoRootDirectory/TEMPLATE_REPO/cloudapptemplate/Waters.logging.Template/content"
GitHubWorkflowTemplateDirectory=${GitHubWorkflowTemplateDirectory//[[:blank:]]/}
MigratedRepositories="$GenesisRepoRootDirectory/migrated_repositories.txt"
NotMigratedRepositories="$GenesisRepoRootDirectory/not_migrated_repositories.txt"

echo -e "${green}"
echo -e "***********************************************"
echo -e "    BitBucket => GitHub Migration Activities"
echo -e "***********************************************"
echo -e "   [1] Clone BitBucket Repository"
echo -e "   [2] Rename master -> main Branch"
echo -e "   [3] Create GitHub Repository"
echo -e "   [4] Fetch GitHub Team ID"
echo -e "   [5] Apply Policies to GitHub Repository"
echo -e "   [6] Add GitHub Workflow Templates"
echo -e "   [7] Apply Protection on Main Branch"
echo -e "\n${reset}\n"

if [ -s "$MigratedRepositories" ]; then
   awk 'NR==FNR{a[$0];next} !($0 in a) ' $MigratedRepositories $repoFile > $NotMigratedRepositories
   cat $NotMigratedRepositories > $repoFile
fi

repositoyForMigration=$(awk '!/^ *#/ && NF' "$repoFile")

for repository in $repositoyForMigration; do
  repository=${repository//[[:blank:]]/} 
  GitHubRepository=$(cut -f2 -d ':' -s <<< "$repository")
  [ -z "$GitHubRepository" ] && exitWrapper "pass GitHub repository name in $repoFile to proceed with migration, exiting..."
  repository=$(cut -f1 -d ':' -s <<< "$repository")
  [ -z "$repository" ] && exitWrapper "pass BitBucket repository name in $repoFile to proceed with migration, exiting..."
  repositoryDirectory=${repository%.*}
  BitBucketDirectory="$rootDirectory/$repositoryDirectory/BitBucket"
  GitHubDirectory="$rootDirectory/$repositoryDirectory/GitHub"
  GitHubCloneDirectory="$GitHubDirectory/templates"
  ValidationDirectory="$rootDirectory/$repositoryDirectory/Validation"
  rm -rf "$BitBucketDirectory" "$GitHubDirectory" "$ValidationDirectory"
  mkdir -p "$BitBucketDirectory" "$GitHubDirectory" "$ValidationDirectory" || exitWrapper "failed to create required root directories, exiting..." 
  checkBitBucketOpenPullRequest
  getGitHubTeamID
  ACCESS_TOKEN=$(awk '$1=="machine"{if(m)exit 1;if($2==M)m=1} m&&$1=="password"{print $2;exit}' M=api.github.com "$HOME"/.netrc)
  [ -z "$ACCESS_TOKEN" ] && exitWrapper "failed to fetch ACCESS_TOKEN from $HOME/.netrc, exiting..."
  export ACCESS_TOKEN=$ACCESS_TOKEN
  runPythonWrapper
  bitBucketRepositoryTasks
  gitHubRepositoryTasks
  cloneGitHubRepository
  validateMigration
  pushGitHubWorkflowTemplates
  cd "$GenesisRepoRootDirectory" || exitWrapper "Failed to switch to the directory $GenesisRepoRootDirectory, exiting..."
  python -c "from main import set_branch_protection;set_branch_protection(\"$GitHubRepository\",\"$gitBranch\");" || exitWrapper " failed to apply branch protection on main branch, exiting..."
  echo -e "${cyan}\xE2\x9C\x94 branch protection of main branch applied sucessfully..."
  {
      echo "$repository:$GitHubRepository" 
  } >> $MigratedRepositories
  done
echo -e "$reset"
