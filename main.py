#!/usr/bin/python

import sys, getopt

import argparse
import requests
import json
from base64 import b64encode
from nacl import encoding, public
import os
import subprocess
import base64
import time
from aws_ecr import create_repository
from enum import Enum
### CONSTANTS ###
#SRE_TEAM_ID=4324218
ORG_ID=63781304
ORG_NAME = "anand-57"
ACCESS_TOKEN = str(os.environ['ACCESS_TOKEN'])
class TemplateType(Enum):
    EMPTY = 0
    BACKEND_ONLY = 1 
    ANGULAR_APP = 2

SECRETS = ["TOKEN_SECRET", "EKS_REGION", "AWS_ACCESS_KEY_ID", "AWS_ACCOUNT_ID", "AWS_SECRET_ACCESS_KEY", "ECR_REGION" ,"EKS_CLUSTER_NAME", "PACT_BROKER_API_KEY"]
header = {"Accept": "application/vnd.github.v3+json"}
parser = argparse.ArgumentParser(description='Initializes github repository.')
parser.add_argument('name',  type=str,
                help='Repository name, capitalization is important')
parser.add_argument('--team',  type=str,
                help='Team name, capitalization is important')
parser.add_argument('--createempty', default=False,
                help='True if create empty repository, default is true', type=lambda x: (str(x).lower() == 'true'))
parser.add_argument('--backendonly',  default=False,
                help='True if backend only, default is false', type=lambda x: (str(x).lower() == 'true'))
parser.add_argument('--desc', type=str, default="Next time, I should provide my repository description using flag --desc",
                help='Provide a short description of your repo here. You can even write a novel if you fancy it')
def getArgs():
    args = parser.parse_args()
    return args.name, args.team, args.backendonly, args.desc, args.createempty

def add_secret_access(projectid, secretname):
    response = requests.put(
        f"https://api.github.com/orgs/{ORG_NAME}/actions/secrets/{secretname}/repositories/{projectid}?access_token={ACCESS_TOKEN}", 
        headers=header
    )
    return response.ok

def make_SRE_team_admin(projectid, name):
    response = requests.put(
                                 
        f"https://api.github.com/orgs/{ORG_NAME}/teams/sre/repos/{ORG_NAME}/{name}?access_token={ACCESS_TOKEN}", 
        headers={"Accept": "application/vnd.github.inertia-preview+json"},
        data=json.dumps({"permission":"admin"})
    )
    return response.ok

def create_code_from_template(name, template_type):
    try:
        as_name = "anand." + name
        docker_tag = name.lower()
        if template_type == TemplateType.BACKEND_ONLY:
            print("\N{thumbs up sign}" + "Creating backend only service")
            return subprocess.check_call(["dotnet", "new", "cloudas", "-o", as_name, "-d", docker_tag, "--force"])
        elif template_type == TemplateType.EMPTY:
            print("\N{thumbs up sign}" + "Creating empty repo with github workflow and chart files")
#            return subprocess.check_call(["dotnet", "new", "-i", "emptyas", "-o", as_name, "-d", docker_tag, "--force"])
            return subprocess.check_call(["dotnet", "new", "-i", "emptyas", "-o", as_name, "--force"])
        else:
            print("\N{thumbs up sign}" + "Creating frontend service")
            return subprocess.check_call(["dotnet", "new", "cloudapp", "-o", as_name, "-d", docker_tag, "--force"])
    except subprocess.CalledProcessError as err:
        print("\N{SKULL AND CROSSBONES}"+"Failed to create code from template, exiting... "+ err)


def get_file_mode(file_name):
    if ".sh" in file_name:
        return "100755"
    else:
        return "100644"

def commit_all_files(name, branch, folder_name, last_commit_sha):
    print("\N{HOURGLASS WITH FLOWING SAND}"+"Creating file commits... ")
    last_tree_sha = None
    rootDir = folder_name
    tree_data = []
    for dirName, subdirList, fileList in os.walk(rootDir):
        #print('Found directory: %s' % dirName)
        dstDir = dirName
        if folder_name+"/.github" in dirName or folder_name+"/chart" in dirName:
            dstDir = dstDir.replace(folder_name+"/",'')
        #print('In directory: %s' % dstDir)
        for fname in fileList:
            base64content = base64.b64encode(open(dirName+"/"+fname, "rb").read())
            response = requests.post(
                f"https://api.github.com/repos/{ORG_NAME}/{name}/git/blobs?access_token={ACCESS_TOKEN}", 
                headers={"Accept":"application/vnd.github.v3+json"},
                data=json.dumps({
                        "content": base64content.decode(),
                        "encoding": "base64"
                    })
            )
            if not response.ok:
                print("\N{SKULL AND CROSSBONES}"+"Failed to create file blob, exiting... "+ response.text)
                return False

            base64_blob_sha = response.json()["sha"]
            tree_data.append({
                    "path": dstDir+"/"+fname,
                    "mode": get_file_mode(fname),
                    "type": "blob",
                    "sha": base64_blob_sha
                    })
    
    print("\N{HOURGLASS WITH FLOWING SAND}"+"Creating file tree... ")
    response = requests.post(
        f"https://api.github.com/repos/{ORG_NAME}/{name}/git/trees?access_token={ACCESS_TOKEN}", 
        headers={"Accept":"application/vnd.github.v3+json"},
        data=json.dumps({
        "base_tree": last_commit_sha,
        "tree": tree_data
    }))

    if not response.ok:
        print("\N{SKULL AND CROSSBONES}"+"Failed to create file tree, exiting... "+ response.text)
        return None

    print("\N{HOURGLASS WITH FLOWING SAND}"+"Commiting files to the repository... ")
    last_tree_sha = response.json()['sha']
    response = requests.post(
        f"https://api.github.com/repos/{ORG_NAME}/{name}/git/commits?access_token={ACCESS_TOKEN}", 
        headers={"Accept":"application/vnd.github.v3+json"},
        data=json.dumps({
            "message": "Initial commit",
            "author": {
                "name": "SRE TEAM",
                "email": ""
            },
            "parents": [
                last_commit_sha
            ],
            "tree": last_tree_sha
            })
    )

    if not response.ok:
        print("\N{SKULL AND CROSSBONES}"+"Failed to create file blob, exiting... "+ response.text)
        return None

    last_commit_sha = response.json()['sha']
    return last_commit_sha


def set_branch_protection(name, branch):


    data = {
        "required_status_checks":{"strict":True,"contexts":["contexts"]},
        "enforce_admins": True,
        "required_pull_request_reviews": {
            "required_approving_review_count":2,
            "require_code_owner_reviews": True,
            "dismissal_restrictions":{"users":[], "teams":["sre"]}
        },
        "restrictions": None,
        "allow_deletions": False
        }

    response = requests.put(
        f"https://api.github.com/repos/{ORG_NAME}/{name}/branches/{branch}/protection?access_token={ACCESS_TOKEN}", 
        headers={"Accept":"application/vnd.github.luke-cage-preview+json"},
        data = json.dumps(data)
    )
    return response.ok

def add_files(name, branch,code_folder_name):
 
    last_commit_sha = get_last_commit_sha(name, branch)
    last_commit_sha = commit_all_files(name, branch,code_folder_name, last_commit_sha)
    if not last_commit_sha:
        print("\N{SKULL AND CROSSBONES}"+ "Failed to delete repository, exiting... ")
        return False

    response = requests.patch(
        f"https://api.github.com/repos/{ORG_NAME}/{name}/git/refs/heads/{branch}?access_token={ACCESS_TOKEN}", 
        headers={"Accept":"application/vnd.github.v3+json"},
        data=json.dumps({
        "sha": last_commit_sha,
        "force":True
            }
        )
    )
    if not response.ok:
        print("\N{SKULL AND CROSSBONES}"+"Failed to update repository commit reference, exiting... "+ response.text)
        return False

    return True

def get_last_commit_sha(name, branch):
    response = requests.get(
        f"https://api.github.com/repos/{ORG_NAME}/{name}/branches/{branch}?access_token={ACCESS_TOKEN}", 
        headers={"Accept":"application/vnd.github.v3+json"})
    if not response.ok:
        print("\N{SKULL AND CROSSBONES}"+ "Failed get last commit sha, exiting... " + response.text)
        return

    last_commit_sha = response.json()['commit']['sha']
    return last_commit_sha

def cleanup_repo(name):
    response = requests.delete(
        f"https://api.github.com/repos/{ORG_NAME}/{name}?access_token={ACCESS_TOKEN}", 
        headers={"Accept":"application/vnd.github.v3+json"}
    )
    if not response.ok:
        print("\N{SKULL AND CROSSBONES}"+ "Failed to delete repository, exiting... " + response.text)
        return
    print("\N{thumbs up sign}" + "Delete Done!")

def createRepo(name, team, desc, template_type):
    result = create_code_from_template(name, template_type)
    if result != 0: 
        print("\N{SKULL AND CROSSBONES}"+ "Failed to create template from code, please check logs, exiting...")
        return
    print("\N{thumbs up sign}" + "Code created from the template!")

    projectid = None

    data={
            "name": name,
            "owner":ORG_NAME,
            "description": desc,
            "private": True,
            "visibility": "private",
            "has_issues": True,
            "has_projects": True,
            "has_wiki": True,
            "team_id":team,
            "delete_branch_on_merge":True,
            "auto_init":True
        }
    
    response = requests.post(
        f"https://api.github.com/orgs/{ORG_NAME}/repos?access_token={ACCESS_TOKEN}", 
        headers={"Accept":"application/vnd.github.v3+json"},
        data = json.dumps(data)
    )
    
    if not response.ok:
        print(response)
        print("\N{SKULL AND CROSSBONES}"+ "Failed to create repository, exiting... ")
        #return
    else:
        data = response.json()
        projectid = data['id']
    print("\N{thumbs up sign}" + "Repository created!")


    folder_name = "anand." + name
    response = add_files(name, "main", folder_name)
    if not response:
       print("\N{SKULL AND CROSSBONES}"+"Failed to add files to the repository, exiting... ")
       cleanup_repo(name)
       return
    print("\N{thumbs up sign}" + "Files checked in!")

    response = make_SRE_team_admin(projectid, name)
    if not response:
        print("\N{SKULL AND CROSSBONES}"+"Failed to make SRE team admin, exiting... ")
        cleanup_repo(name)
        return
    print("\N{thumbs up sign}" + "Made SRE team admin!")


    for secret in SECRETS:
        if not add_secret_access(projectid, secret):
           print("\N{SKULL AND CROSSBONES}"+"Failed to add secrets, exiting... ")
           cleanup_repo(name)
           return
    print("\N{thumbs up sign}" + "Added secrets!")


    response = set_branch_protection(name.lower(), "main")
    if not response:
       print("\N{SKULL AND CROSSBONES}"+"Failed to set branch protections, exiting... ")
       cleanup_repo(name)
       return

    print("\N{thumbs up sign}" + "Set branch protections!")
    
    try :
        response = create_repository(name)
        print("\N{thumbs up sign}" + "Created ECR Repo!")
    except Exception as ex:
        print(ex)
        print("\N{SKULL AND CROSSBONES}"+"Failed to create ECR, exiting... ")
        cleanup_repo(name)

    print("\N{thumbs up sign}" + "Done!")

    time.sleep(200)
    cleanup_repo(name)

#############################################################
##### This function is created just for migration which #####
##### will be removed once migration is done            #####
#############################################################
def migration(name, team, backendonly, desc, empty):
    projectid = None
    data={
        "name": name,
        "owner": ORG_NAME,
        "description": desc,
        "private": True,
        "visibility": "private",
        "has_issues": True,
        "has_projects": True,
        "has_wiki": True,
        "team_id": team,
        "delete_branch_on_merge": True,
        "auto_init": True
    }
   
    response = requests.post(
        f"https://api.github.com/orgs/{ORG_NAME}/repos?access_token={ACCESS_TOKEN}",
        headers={"Accept":"application/vnd.github.v3+json"},
        data = json.dumps(data)
    )
   
    if not response.ok:
        print(response)
        print("\N{SKULL AND CROSSBONES}"+ "Failed to create repository, exiting... ")
        return
    else:
        data = response.json()
        projectid = data['id']
    print("\N{thumbs up sign}" + "Repository created!")
    response = make_SRE_team_admin(projectid, name)
    if not response:
        print("\N{SKULL AND CROSSBONES}"+"Failed to make SRE team admin, exiting... ")
        cleanup_repo(name)
        return
    print("\N{thumbs up sign}" + "Made SRE team admin!")

    for secret in SECRETS:
        if not add_secret_access(projectid, secret):
           print("\N{SKULL AND CROSSBONES}"+"Failed to add secrets, exiting... ")
           return
    print("\N{thumbs up sign}" + "Added secrets!")

if __name__ == "__main__":
    name, team, backendonly, desc, empty = getArgs()
    template_type = TemplateType.EMPTY
    if empty:
        template_type = TemplateType.EMPTY
    elif backendonly:
        template_type = TemplateType.BACKEND_ONLY
    else:
        template_type = TemplateType.ANGULAR_APP

    createRepo(name, team, desc, template_type)
  
