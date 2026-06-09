import json
import boto3
import os

# Initialize the DynamoDB resource
dynamodb = boto3.resource('dynamodb')

# We will pass the table name in via Terraform environment variables
table_name = os.environ.get('TABLE_NAME', 'resume-visitor-count')
table = dynamodb.Table(table_name)

def lambda_handler(event, context):
    try:
        # Atomic update: Increments the 'visits' attribute by 1
        response = table.update_item(
            Key={'id': 'counter'},
            UpdateExpression='ADD visits :inc',
            ExpressionAttributeValues={':inc': 1},
            ReturnValues='UPDATED_NEW'
        )
        
        # Extract the newly updated count
        new_count = int(response['Attributes']['visits'])
        
        return {
            'statusCode': 200,
            'headers': {
                # CORS headers are required so your browser allows the request
                'Access-Control-Allow-Origin': '*', 
                'Content-Type': 'application/json'
            },
            'body': json.dumps({'visit_count': new_count})
        }
        
    except Exception as e:
        print(f"Error updating database: {e}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': 'Could not update visitor count'})
        }