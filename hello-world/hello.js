/**
 * Copyright (c) HashiCorp, Inc.
 * SPDX-License-Identifier: MPL-2.0
 */

// Lambda function code
var AWS = require("aws-sdk");

module.exports.handler = async (event) => {
  console.log('Event: ', event);
  let responseMessage = 'Hello, World!';

  var sqs = new AWS.SQS({ apiVersion: "2012-11-05" });

  // Write to SQS queue if the event if from the API GW endpoint
  if (event.path === '/serverless_lambda_stage/hello') {
    console.log('From API GW endpoint. Writing to SQS queue');
    await sqs.sendMessage({
      QueueUrl: process.env.QUEUE_URL,
      MessageBody: JSON.stringify(event),
      // MessageGroupId: '1',
    }).promise();
  } else {
    console.log('Not from API GW endpoint. Likely SQS event');
  }

  return {
    statusCode: 200,
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      message: responseMessage,
    }),
  }
}
