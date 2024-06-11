exports.handler = async (event) => {
    return {
        statusCode: 200,
        body: JSON.stringify('Hello for Function 2!'),
    };
};
