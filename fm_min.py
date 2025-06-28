import re
import htmlmin
import argparse
# import json
# import sys

def minify_fullmoon_html(input_file, output_file):
    """
    Minify a Fullmoon template without affecting Fullmoon template tags.

    Args:
        input_file (str): The path to the Fullmoon template input file.
        output_file (str): The path to the output file where minified HTML will be saved.
    """
    # Read the input file
    with open(input_file, 'r') as file:
        content = file.read()

    # Define regex patterns for Fullmoon template tags
    fullmoon_tags = r'({%[#&=]?.*?%})'

    # Split the content into Django tags and HTML
    parts = re.split(fullmoon_tags, content)

    # json.dump(parts, sys.stdout)
    # Minify only the HTML parts
    for i in range(len(parts)):
        part = parts[i]
        # print(f"\tExamining: ||{part}||")
        if not re.match(fullmoon_tags, part):
            # print("\t\tNot an FM template string, formatting")
            parts[i] = htmlmin.minify(part, remove_empty_space=True, remove_all_empty_space=True)

    # Join the parts back together
    minified_content = ''.join(parts)

    # Write the minified content to the output file
    with open(output_file, 'w') as file:
        file.write(minified_content)

    # print(f"Minified HTML has been saved to {output_file}")


def main():
    # Set up argument parser
    parser = argparse.ArgumentParser(description="Minify a Fullmoon HTML template while preserving template tags.")
    
    # Add arguments for input and output file paths
    parser.add_argument('input_file', type=str, help="Path to the input Fullmoon template file")
    parser.add_argument('output_file', type=str, help="Path to save the minified HTML file")

    # Parse the arguments
    args = parser.parse_args()

    # Call the minification function with the provided arguments
    minify_fullmoon_html(args.input_file, args.output_file)


if __name__ == "__main__":
    main()
