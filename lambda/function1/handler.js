exports.handler = async (event) => {
    return {
        statusCode: 200,
        body: JSON.stringify('Testing the provisioned concurrency 2nd time for Function 1!'),
    };
};
