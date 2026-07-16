#!/bin/bash
ENVPY=".venv/bin/python"
ACTIVATE=".venv/bin/activate"
ANSIBLE_VER="2.18.0"

uv venv
echo "RUN: source $ACTIVATE"
echo "RUN: uv pip install --python $ENVPY ansible-core==$ANSIBLE_VER"
