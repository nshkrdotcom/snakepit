#!/usr/bin/env python3
"""
Generate Python gRPC code from protobuf files.
"""

import os
import sys
import subprocess

def main():
    # Get the directory paths
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.abspath(os.path.join(script_dir, '..', '..'))
    proto_dir = os.path.join(project_root, 'priv', 'proto')
    output_dir = os.path.join(script_dir, 'snakepit_bridge')
    
    # Ensure output directory exists
    os.makedirs(output_dir, exist_ok=True)
    
    # Proto file
    proto_file = os.path.join(proto_dir, 'snakepit_bridge.proto')
    
    # Generate Python code
    cmd = [
        'python', '-m', 'grpc_tools.protoc',
        f'--proto_path={proto_dir}',
        f'--python_out={output_dir}',
        f'--grpc_python_out={output_dir}',
        proto_file
    ]
    
    print(f"Generating Python gRPC code...")
    print(f"Command: {' '.join(cmd)}")
    
    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error: {result.stderr}")
            sys.exit(1)
        else:
            print("Successfully generated Python gRPC code!")
            
            # Fix imports in the generated files
            grpc_file = os.path.join(output_dir, 'snakepit_bridge_pb2_grpc.py')
            if os.path.exists(grpc_file):
                with open(grpc_file, 'r') as f:
                    content = f.read()
                
                # Replace absolute import with relative import
                content = content.replace('import snakepit_bridge_pb2', 'from . import snakepit_bridge_pb2')
                
                with open(grpc_file, 'w') as f:
                    f.write(content)
                
                print("Fixed imports in generated files.")
    
    except Exception as e:
        print(f"Error running protoc: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()